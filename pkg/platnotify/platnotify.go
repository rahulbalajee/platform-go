// START head OMIT

// Package platnotify is the SDK for plat's notifier plugins: programs that
// plat starts after a deployment finishes, to tell a chat room, an incident
// tool or an audit log. A plugin is a separate executable that implements
// Notifier and calls Serve from main; plat talks to it over gRPC, through
// HashiCorp's go-plugin, the plugin system of Terraform, Vault and Packer.
//
// A plugin is a process of its own: if it crashes or hangs, plat carries
// on, and it can be written against any version of this package that
// speaks protocol version 1.
package platnotify

// END head OMIT
// START imports OMIT

import (
	"context"
	"io"
	"os/exec"
	"time"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/go-plugin"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/timestamppb"

	"github.com/rahulbalajee/platform-go/pkg/platnotify/notifyv1"
)

// END imports OMIT
// START api OMIT

// Event is a finished deployment.
type Event struct {
	ID, Service, Environment, Version string
	State                             string // succeeded, failed, cancelled; "test"
	Reason, User                      string
	FinishedAt                        time.Time
}

// Notifier is what a plugin implements. Notify returns a short note on
// what it did ("posted to #deploys"), which plat prints.
type Notifier interface {
	Notify(ctx context.Context, e Event) (string, error)
}

// Handshake is checked by both sides before anything else. The protocol
// version changes only when the protocol does; the cookie is not a secret
// but a guard: run by hand, a plugin finds no cookie in its environment
// and says it is a plugin, instead of waiting for a host that isn't there.
var Handshake = plugin.HandshakeConfig{
	ProtocolVersion:  1,
	MagicCookieKey:   "PLAT_NOTIFIER_PLUGIN",
	MagicCookieValue: "a plat notifier: run it from plat, not by hand",
}

// pluginName is the name the plugin is dispensed under.
const pluginName = "notifier"

// END api OMIT
// START serve OMIT

// Serve is the whole main function of a notifier plugin. It does not
// return until plat closes the connection.
func Serve(n Notifier) {
	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig: Handshake,
		Plugins:         plugin.PluginSet{pluginName: &grpcPlugin{impl: n}},
		GRPCServer:      plugin.DefaultGRPCServer,
	})
}

// grpcPlugin connects a Notifier to go-plugin's gRPC transport, in both
// directions: GRPCServer runs in the plugin, GRPCClient in plat.
type grpcPlugin struct {
	plugin.NetRPCUnsupportedPlugin
	impl Notifier
}

func (p *grpcPlugin) GRPCServer(_ *plugin.GRPCBroker, s *grpc.Server) error {
	notifyv1.RegisterNotifierServiceServer(s, &server{impl: p.impl})
	return nil
}

func (p *grpcPlugin) GRPCClient(_ context.Context, _ *plugin.GRPCBroker,
	c *grpc.ClientConn,
) (any, error) {
	return &client{rpc: notifyv1.NewNotifierServiceClient(c)}, nil
}

// server adapts a Notifier to the generated gRPC service.
type server struct {
	notifyv1.UnimplementedNotifierServiceServer
	impl Notifier
}

func (s *server) Notify(ctx context.Context, req *notifyv1.NotifyRequest,
) (*notifyv1.NotifyResponse, error) {
	d := req.GetDeployment()
	detail, err := s.impl.Notify(ctx, Event{ID: d.GetId(),
		Service: d.GetService(), Environment: d.GetEnvironment(),
		Version: d.GetVersion(), State: d.GetState(), Reason: d.GetReason(),
		User: d.GetUser(), FinishedAt: d.GetFinishedAt().AsTime()})
	if err != nil {
		return nil, err
	}
	return &notifyv1.NotifyResponse{Detail: detail}, nil
}

// END serve OMIT
// START client OMIT

// client is the Notifier plat holds: each call is a gRPC call into the
// plugin process.
type client struct {
	rpc notifyv1.NotifierServiceClient
}

func (c *client) Notify(ctx context.Context, e Event) (string, error) {
	resp, err := c.rpc.Notify(ctx, &notifyv1.NotifyRequest{
		Deployment: &notifyv1.Deployment{Id: e.ID, Service: e.Service,
			Environment: e.Environment, Version: e.Version, State: e.State,
			Reason: e.Reason, User: e.User,
			FinishedAt: timestamppb.New(e.FinishedAt)}})
	if err != nil {
		return "", err
	}
	return resp.GetDetail(), nil
}

// Plugin is a running notifier plugin.
type Plugin struct {
	Notifier
	client *plugin.Client
}

// Start runs the plugin command and connects to it. The connection is
// mutually authenticated TLS with certificates made for this run, so no
// other local process can talk to the plugin. The plugin's own log lines
// go to logs. Close the Plugin to stop the process.
func Start(cmd *exec.Cmd, logs io.Writer) (*Plugin, error) {
	c := plugin.NewClient(&plugin.ClientConfig{
		HandshakeConfig:  Handshake,
		Plugins:          plugin.PluginSet{pluginName: &grpcPlugin{}},
		Cmd:              cmd,
		AllowedProtocols: []plugin.Protocol{plugin.ProtocolGRPC},
		AutoMTLS:         true,
		StartTimeout:     10 * time.Second,
		Logger: hclog.New(&hclog.LoggerOptions{Name: "notifier",
			Output: logs, Level: hclog.Warn}),
	})
	rpc, err := c.Client()
	if err != nil {
		c.Kill()
		return nil, err
	}
	raw, err := rpc.Dispense(pluginName)
	if err != nil {
		c.Kill()
		return nil, err
	}
	return &Plugin{Notifier: raw.(Notifier), client: c}, nil
}

// Close stops the plugin process.
func (p *Plugin) Close() { p.client.Kill() }

// END client OMIT
