package filter

import (
	"encoding/json"
	"strings"
)

// EndpointRule defines which keys to remove for a given URL path prefix.
type EndpointRule struct {
	Path       string
	RemoveKeys map[string]struct{}
}

// Filter holds the set of endpoint rules.
type Filter struct {
	rules []EndpointRule
}

// New creates a Filter from a list of endpoint configs.
func New(rules []EndpointRule) *Filter {
	return &Filter{rules: rules}
}

// ShouldFilter returns true if the given path matches any rule.
func (f *Filter) ShouldFilter(path string) bool {
	for _, r := range f.rules {
		if strings.HasPrefix(path, r.Path) {
			return true
		}
	}
	return false
}

// Apply parses body as JSON, removes ad keys recursively, and re-encodes.
// Returns original body unchanged if parsing fails.
func (f *Filter) Apply(path string, body []byte) []byte {
	var rule *EndpointRule
	for i, r := range f.rules {
		if strings.HasPrefix(path, r.Path) {
			rule = &f.rules[i]
			break
		}
	}
	if rule == nil {
		return body
	}

	var data interface{}
	if err := json.Unmarshal(body, &data); err != nil {
		return body
	}

	cleaned := removeKeys(data, rule.RemoveKeys)

	out, err := json.Marshal(cleaned)
	if err != nil {
		return body
	}
	return out
}

// removeKeys recursively removes specified keys from JSON structure.
func removeKeys(v interface{}, keys map[string]struct{}) interface{} {
	switch val := v.(type) {
	case map[string]interface{}:
		result := make(map[string]interface{}, len(val))
		for k, child := range val {
			if _, blocked := keys[k]; blocked {
				continue
			}
			result[k] = removeKeys(child, keys)
		}
		return result
	case []interface{}:
		result := make([]interface{}, 0, len(val))
		for _, item := range val {
			result = append(result, removeKeys(item, keys))
		}
		return result
	default:
		return v
	}
}
