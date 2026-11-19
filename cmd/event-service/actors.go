package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strings"
	"unicode"
)

type actor struct {
	Kind   string
	ID     string
	shared bool
}

func (a actor) canReview() bool {
	return a.Kind == "user" || a.shared
}

type actorKey struct{}

func requestActor(ctx context.Context) actor {
	return ctx.Value(actorKey{}).(actor)
}

type credentials map[[sha256.Size]byte]actor

func loadCredentials() (credentials, error) {
	tokens := make(credentials)
	path := os.Getenv("API_TOKENS_FILE")
	if path == "" {
		token := os.Getenv("API_TOKEN")
		if strings.TrimSpace(token) == "" {
			return nil, errors.New("set API_TOKENS_FILE or API_TOKEN")
		}
		id := strings.TrimSpace(os.Getenv("API_ACTOR_ID"))
		if id == "" {
			id = "local-client"
		}
		tokens[sha256.Sum256([]byte(token))] = actor{Kind: "service", ID: id, shared: true}
		return tokens, nil
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	var entries []struct {
		Kind  string `json:"kind"`
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	dec := json.NewDecoder(file)
	dec.DisallowUnknownFields()
	if dec.Decode(&entries) != nil || dec.Decode(new(json.RawMessage)) != io.EOF || len(entries) == 0 {
		return nil, errors.New("API_TOKENS_FILE must contain a nonempty JSON array of actors")
	}
	for _, entry := range entries {
		if (entry.Kind != "user" && entry.Kind != "service") || strings.TrimSpace(entry.ID) == "" ||
			entry.ID != strings.TrimSpace(entry.ID) || strings.IndexFunc(entry.ID, unicode.IsControl) >= 0 ||
			entry.Token == "" || strings.IndexFunc(entry.Token, func(r rune) bool { return r < 33 || r > 126 }) >= 0 {
			return nil, errors.New("invalid actor kind, id or token in API_TOKENS_FILE")
		}
		key := sha256.Sum256([]byte(entry.Token))
		if _, exists := tokens[key]; exists {
			return nil, errors.New("duplicate token in API_TOKENS_FILE")
		}
		tokens[key] = actor{Kind: entry.Kind, ID: entry.ID}
	}
	return tokens, nil
}
