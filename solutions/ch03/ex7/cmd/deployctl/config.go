package main

// START imports OMIT
import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"

	"deployctl/pkg/clierr"
)

// END imports OMIT

// START config OMIT
// Config is deployctl.json.
type Config struct {
	API     string   `json:"api"`     // base URL of the deployment API
	Service string   `json:"service"` // what to deploy
	Targets []string `json:"targets"` // where to deploy it
}

// END config OMIT
// START load OMIT
// loadConfig reads and validates the config file. Every failure is a
// clierr.Error with the same ID, so the docs link and the hint are right
// whichever way the file is wrong.
func loadConfig(path string) (Config, error) {
	var cfg Config
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return cfg, configError(clierr.ExitUsage, err,
			fmt.Sprintf("config file %s not found", path),
			`run "deployctl init" to create one, or pass -config FILE`)
	case err != nil: // Code 0: CodeOf infers 77 for EACCES, 1 otherwise
		return cfg, configError(0, err,
			fmt.Sprintf("cannot read config file %s", path),
			"check the file's owner and mode with ls -l")
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, configError(clierr.ExitUsage, err,
			fmt.Sprintf("config file %s is not valid JSON", path),
			"fix the syntax; the cause below says where")
	}
	var problems []error
	if cfg.API == "" {
		problems = append(problems, errors.New(`"api" is empty`))
	}
	if len(cfg.Targets) == 0 {
		problems = append(problems, errors.New(`"targets" is empty`))
	}
	if err := errors.Join(problems...); err != nil {
		return cfg, configError(clierr.ExitUsage, err,
			fmt.Sprintf("config file %s is incomplete", path), "")
	}
	return cfg, nil
}

func configError(code clierr.Code, err error, msg, hint string) error {
	return &clierr.Error{Code: code, ID: "DPL-CONFIG", Message: msg,
		Hint: hint, Docs: docs + "#dpl-config", Err: err}
}

// END load OMIT
// START init OMIT
// initConfig writes a starter config, refusing to overwrite an existing one.
func initConfig(path string, stdout io.Writer) error {
	data, _ := json.MarshalIndent(Config{
		API:     "http://127.0.0.1:8787",
		Service: "checkout",
		Targets: []string{"us-east-1", "eu-west-1"},
	}, "", "  ")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return &clierr.Error{Code: clierr.ExitUsage, ID: "DPL-CONFIG",
			Message: fmt.Sprintf("%s already exists", path),
			Hint:    "edit it, or remove it first", Err: err}
	}
	if err != nil {
		return err
	}
	_, err = f.Write(append(data, '\n'))
	if err := errors.Join(err, f.Close()); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "wrote %s\n", path)
	return nil
}

// END init OMIT
