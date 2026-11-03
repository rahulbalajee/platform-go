// START imports OMIT
package main

import (
	"encoding/json"
	"fmt"
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
	if err != nil {
		return cfg, fmt.Errorf("load config: %w", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("load config %s: %w", path, err)
	}
	return cfg, nil
}

// END load OMIT
