package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"
)

func withWebUI(api http.Handler, dir string) http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /ui/", http.StripPrefix("/ui", http.FileServer(http.Dir(dir))))
	mux.Handle("/", api)
	return mux
}

func run() error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("set DATABASE_URL")
	}
	tokens, err := loadCredentials()
	if err != nil {
		return err
	}
	var hooks []*webhook
	for _, queue := range []deliveryQueue{attachmentQueue, eventQueue} {
		hook, err := newWebhook(queue, os.Getenv(queue.configPrefix+"_WEBHOOK_URL"), os.Getenv(queue.configPrefix+"_WEBHOOK_TOKEN"))
		if err != nil {
			return err
		}
		if hook != nil {
			hooks = append(hooks, hook)
		}
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return err
	}
	defer db.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		return err
	}
	server := http.Server{
		Addr: addr, Handler: withWebUI(newHandler(db, tokens, 25*time.Second), "web/dist"), ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second,
	}
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	workerCtx, stop := context.WithCancel(context.Background())
	var workers sync.WaitGroup
	for _, hook := range hooks {
		workers.Add(1)
		go func() { defer workers.Done(); hook.run(workerCtx, db) }()
	}
	defer func() { stop(); workers.Wait() }()
	log.Printf("event API listening on %s", listener.Addr())
	return server.Serve(listener)
}

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
