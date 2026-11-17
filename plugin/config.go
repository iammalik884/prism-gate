package main

// Config is read from the plugin's "config" object in Bifrost's config.json.
type Config struct {
	BrainURL          string
	BrainTimeoutMS    int
	LocalProvider     string
	LocalModel        string
	MaxConcurrent     int
	EmergencyReserved int
	AdmitTimeoutMS    int
}

func defaultConfig() Config {
	return Config{
		BrainURL:          "http://127.0.0.1:8090",
		BrainTimeoutMS:    50,
		LocalProvider:     "ollama",
		LocalModel:        "qwen2.5:1.5b",
		MaxConcurrent:     8,
		EmergencyReserved: 2,
		AdmitTimeoutMS:    20000,
	}
}

func (c *Config) apply(m map[string]interface{}) {
	if v, ok := m["brain_url"].(string); ok && v != "" {
		c.BrainURL = v
	}
	if v, ok := m["local_provider"].(string); ok && v != "" {
		c.LocalProvider = v
	}
	if v, ok := m["local_model"].(string); ok && v != "" {
		c.LocalModel = v
	}
	// JSON numbers arrive as float64.
	if v, ok := m["brain_timeout_ms"].(float64); ok && v > 0 {
		c.BrainTimeoutMS = int(v)
	}
	if v, ok := m["max_concurrent"].(float64); ok && v > 0 {
		c.MaxConcurrent = int(v)
	}
	if v, ok := m["emergency_reserved"].(float64); ok && v >= 0 {
		c.EmergencyReserved = int(v)
	}
	if v, ok := m["admit_timeout_ms"].(float64); ok && v > 0 {
		c.AdmitTimeoutMS = int(v)
	}
}
