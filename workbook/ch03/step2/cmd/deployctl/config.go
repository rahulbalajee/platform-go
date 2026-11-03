// START imports OMIT
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
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
// loadConfig reads and parses the config file. Each failure gets the
// context the caller lacks, and keeps its cause with %w.
func loadConfig(path string) (Config, error) {
	var cfg Config
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, fs.ErrNotExist): // a sentinel: compare, don't parse
		return cfg, fmt.Errorf("config file %s not found "+
			`(run "deployctl init" to create one): %w`, path, err)
	case err != nil:
		return cfg, fmt.Errorf("load config: %w", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("load config %s: %w", path, err)
	}
	return cfg, nil
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
		return fmt.Errorf("%s already exists; edit it, or remove it first: %w",
			path, err)
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
