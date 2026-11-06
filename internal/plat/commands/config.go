package commands

// START imports OMIT

import (
	"fmt"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"sigs.k8s.io/yaml"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/cli"
	"github.com/rahulbalajee/platform-go/pkg/cli/config"
	"github.com/rahulbalajee/platform-go/pkg/clierr"
)

// END imports OMIT
// START group OMIT

func newConfigCmd(f *factory.Factory) *cobra.Command {
	cmd := cli.Group(&cobra.Command{
		Use:   "config",
		Short: "Manage contexts: which platform plat talks to, and how",
		Long: `A context is a named platform server and the way to log in to it.
plat uses the current context unless --context or PLAT_CONTEXT names
another, and --server or PLAT_SERVER overrides the context's server.`,
	})
	cmd.AddCommand(
		&cobra.Command{
			Use: "view", Short: "Print the configuration file",
			Args: cli.ExactArgs(),
			RunE: func(*cobra.Command, []string) error { return runConfigView(f) },
		},
		&cobra.Command{
			Use: "get-contexts", Short: "List contexts",
			Args: cli.ExactArgs(),
			RunE: func(*cobra.Command, []string) error { return runGetContexts(f) },
		},
		&cobra.Command{
			Use: "current-context", Short: "Print the current context's name",
			Args: cli.ExactArgs(),
			RunE: func(*cobra.Command, []string) error {
				return runCurrentContext(f)
			},
		},
		&cobra.Command{
			Use: "use-context NAME", Short: "Make NAME the current context",
			Args:              cli.ExactArgs("NAME"),
			ValidArgsFunction: completeContexts(f),
			RunE: func(_ *cobra.Command, args []string) error {
				return runUseContext(f, args[0])
			},
		},
		newSetContextCmd(f),
		&cobra.Command{
			Use:               "delete-context NAME",
			Short:             "Delete a context and its stored login",
			Args:              cli.ExactArgs("NAME"),
			ValidArgsFunction: completeContexts(f),
			RunE: func(_ *cobra.Command, args []string) error {
				return runDeleteContext(f, args[0])
			},
		},
	)
	return cmd
}

// END group OMIT
// START view OMIT

func runConfigView(f *factory.Factory) error {
	file, err := f.Config()
	if err != nil {
		return err
	}
	out, err := yaml.Marshal(file)
	if err != nil {
		return err
	}
	_, err = f.IO.Out.Write(out)
	return err
}

func runGetContexts(f *factory.Factory) error {
	file, err := f.Config()
	if err != nil {
		return err
	}
	tw := tabwriter.NewWriter(f.IO.Out, 0, 0, 3, ' ', 0)
	fmt.Fprintln(tw, "CURRENT\tNAME\tSERVER\tPROVIDER")
	for _, name := range file.Names() {
		c, _ := file.Context(name)
		cur := ""
		if name == file.CurrentContext {
			cur = "*"
		}
		provider := c.Provider
		if provider == "" {
			provider = "oidc"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", cur, c.Name, c.Server, provider)
	}
	return tw.Flush()
}

func runCurrentContext(f *factory.Factory) error {
	file, err := f.Config()
	if err != nil {
		return err
	}
	if file.CurrentContext == "" {
		return &clierr.Error{Message: "no current context is set",
			Hint: "Set one with 'plat config use-context NAME'."}
	}
	_, err = fmt.Fprintln(f.IO.Out, file.CurrentContext)
	return err
}

// END view OMIT
// START use OMIT

func runUseContext(f *factory.Factory, name string) error {
	file, err := f.Config()
	if err != nil {
		return err
	}
	if _, ok := file.Context(name); !ok {
		return unknownContext(name)
	}
	file.CurrentContext = name
	if err := f.SaveConfig(file); err != nil {
		return err
	}
	_, err = fmt.Fprintf(f.IO.ErrOut, "Switched to context %q\n", name)
	return err
}

// runDeleteContext removes the context and its credentials: a login left
// behind in the keychain for a context nobody can name is a credential
// nobody will ever revoke.
func runDeleteContext(f *factory.Factory, name string) error {
	file, err := f.Config()
	if err != nil {
		return err
	}
	if !file.DeleteContext(name) {
		return unknownContext(name)
	}
	store, err := f.Store()
	if err != nil {
		return err
	}
	if err := store.Delete(name); err != nil {
		return fmt.Errorf("deleting the stored login of %q: %w", name, err)
	}
	if err := f.SaveConfig(file); err != nil {
		return err
	}
	_, err = fmt.Fprintf(f.IO.ErrOut, "Deleted context %q\n", name)
	return err
}

func unknownContext(name string) error {
	return &clierr.Error{Code: clierr.ExitUsage,
		Message: fmt.Sprintf("context %q does not exist", name),
		Hint:    "List contexts with 'plat config get-contexts'."}
}

// END use OMIT
// START set OMIT

func newSetContextCmd(f *factory.Factory) *cobra.Command {
	var c config.Context
	cmd := &cobra.Command{
		Use:   "set-context NAME",
		Short: "Create a context, or change some of its settings",
		Example: `  plat config set-context prod --server https://platform.acme.dev
  plat config set-context gh --server http://127.0.0.1:8484 --provider github`,
		Args: cli.ExactArgs("NAME"),
		RunE: func(cmd *cobra.Command, args []string) error {
			file, err := f.Config()
			if err != nil {
				return err
			}
			cur, exists := file.Context(args[0])
			if !exists && c.Server == "" {
				return cli.UsageError(cmd, fmt.Errorf(
					"context %q is new: --server is required", args[0]))
			}
			// Only the flags given change: the rest of the context stays.
			cur.Name = args[0]
			fl := cmd.Flags()
			if fl.Changed("server") {
				cur.Server = c.Server
			}
			if fl.Changed("provider") {
				cur.Provider = c.Provider
			}
			if fl.Changed("issuer") {
				cur.Issuer = c.Issuer
			}
			if fl.Changed("client-id") {
				cur.ClientID = c.ClientID
			}
			file.SetContext(cur)
			if err := f.SaveConfig(file); err != nil {
				return err
			}
			verb := "Updated"
			if !exists {
				verb = "Created"
			}
			_, err = fmt.Fprintf(f.IO.ErrOut, "%s context %q\n", verb, cur.Name)
			return err
		},
	}
	fl := cmd.Flags()
	fl.StringVar(&c.Server, "server", "", "platform API `URL`")
	fl.StringVar(&c.Provider, "provider", "", "login provider: oidc or github")
	fl.StringVar(&c.Issuer, "issuer", "", "OIDC issuer `URL` (default: the server)")
	fl.StringVar(&c.ClientID, "client-id", "", "OAuth client `ID` to log in as")
	return cmd
}

// completeContexts completes context names from the configuration file.
func completeContexts(f *factory.Factory) cobra.CompletionFunc {
	return func(*cobra.Command, []string, string) (
		[]cobra.Completion, cobra.ShellCompDirective) {
		file, err := f.Config()
		if err != nil {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}
		return file.Names(), cobra.ShellCompDirectiveNoFileComp
	}
}

// END set OMIT
