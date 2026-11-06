package commands

// START imports OMIT

import (
	"context"
	"time"

	"github.com/spf13/cobra"

	"github.com/rahulbalajee/platform-go/internal/plat/factory"
	"github.com/rahulbalajee/platform-go/pkg/platformapi"
)

// END imports OMIT
// START complete OMIT

// completeServices completes service names for the shell by asking the
// platform. Completion runs on every Tab press, so it gets a short deadline
// and fails quietly: a slow or unreachable server must never hang the shell
// or print an error into the middle of the command line.
func completeServices(f *factory.Factory) cobra.CompletionFunc {
	return func(c *cobra.Command, args []string, _ string) (
		[]cobra.Completion, cobra.ShellCompDirective) {
		if len(args) > 0 {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}
		ctx, cancel := context.WithTimeout(c.Context(), 2*time.Second)
		defer cancel()
		client, err := f.Client()
		if err != nil {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}
		var names []cobra.Completion
		for s, err := range client.ListServices(ctx, platformapi.ServiceFilter{}) {
			if err != nil {
				return nil, cobra.ShellCompDirectiveNoFileComp
			}
			names = append(names, cobra.CompletionWithDesc(s.Name, s.Team))
		}
		return names, cobra.ShellCompDirectiveNoFileComp
	}
}

// completeEnvironments completes environment names, like completeServices.
func completeEnvironments(f *factory.Factory) cobra.CompletionFunc {
	return func(c *cobra.Command, _ []string, _ string) (
		[]cobra.Completion, cobra.ShellCompDirective) {
		ctx, cancel := context.WithTimeout(c.Context(), 2*time.Second)
		defer cancel()
		client, err := f.Client()
		if err != nil {
			return nil, cobra.ShellCompDirectiveNoFileComp
		}
		var names []cobra.Completion
		for e, err := range client.ListEnvironments(ctx) {
			if err != nil {
				return nil, cobra.ShellCompDirectiveNoFileComp
			}
			names = append(names, cobra.CompletionWithDesc(e.Name, e.Region))
		}
		return names, cobra.ShellCompDirectiveNoFileComp
	}
}

// END complete OMIT
