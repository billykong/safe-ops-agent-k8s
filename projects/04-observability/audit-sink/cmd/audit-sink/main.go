// audit-sink receives the Kubernetes API server's audit events (P4-04) on
// its webhook backend and appends them to a hash chain on its own volume.
//
//	audit-sink serve   the webhook: mTLS, only the API server's client
//	                   certificate is accepted; metrics on a second port
//	audit-sink verify  re-read a chain file and say where it breaks
//	audit-sink cat     print a chain file's events, one per line
//	audit-sink health  the readiness probe (exec: the kubelet's probes
//	                   reach pods as "world" here and policy drops them)
//
// Nothing else writes to the chain, and it has no API to change or delete
// entries. The agent can't reach the sink (network policy), couldn't
// authenticate if it did (no client certificate from the sink's CA), and
// has no RBAC in its namespace.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"

	"github.com/billykong/safe-ops-agent-k8s/projects/04-observability/audit-sink/internal/chain"
	"github.com/billykong/safe-ops-agent-k8s/projects/04-observability/audit-sink/internal/events"
)

var (
	eventsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "safeops_audit_events_total",
		Help: "Audit events stored, final stage only, by who acted and how the API server answered.",
	}, []string{"actor", "outcome"})
	changesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "safeops_audit_changes_total",
		Help: "Allowed changes to configuration that guards the agent (admission, RBAC, network policy, kill switch).",
	}, []string{"resource", "actor"})
	batchesTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "safeops_audit_batches_total",
		Help: "Batches received from the API server, by result.",
	}, []string{"result"})
	chainEntries = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "safeops_audit_chain_entries",
		Help: "Entries in the chain this sink has written.",
	})
	chainVerified = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "safeops_audit_chain_verified",
		Help: "1 if the chain on disk verified at the last check and matched what this sink wrote, else 0.",
	})
	chainChecked = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "safeops_audit_chain_last_check_timestamp_seconds",
		Help: "When the chain was last re-read from disk.",
	})
)

func init() {
	prometheus.MustRegister(eventsTotal, changesTotal, batchesTotal, chainEntries, chainVerified, chainChecked)
	// Every series exists from the start, so the first increment counts
	// in increase() (P4 finding 6).
	for _, a := range events.Actors {
		for _, o := range events.Outcomes {
			eventsTotal.WithLabelValues(a, o)
		}
		for _, r := range events.Changed {
			changesTotal.WithLabelValues(r, a)
		}
	}
	for _, r := range []string{"ok", "rejected", "write_error"} {
		batchesTotal.WithLabelValues(r)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: audit-sink serve|verify|cat|health [flags]")
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "serve":
		serve(args)
	case "health":
		c := http.Client{Timeout: 3 * time.Second}
		resp, err := c.Get("http://127.0.0.1:9090/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			fmt.Fprintln(os.Stderr, "not healthy:", err)
			os.Exit(1)
		}
	case "verify":
		fs := flag.NewFlagSet("verify", flag.ExitOnError)
		path := fs.String("log", "/data/audit.jsonl", "chain file")
		fs.Parse(args)
		f, err := os.Open(*path)
		if err != nil {
			log.Fatal(err)
		}
		st, err := chain.Verify(f, nil)
		if err != nil {
			fmt.Printf("broken after %d good entries: %v\n", st.Entries, err)
			os.Exit(1)
		}
		fmt.Printf("ok entries=%d head=%s\n", st.Entries, st.Head)
	case "cat":
		fs := flag.NewFlagSet("cat", flag.ExitOnError)
		path := fs.String("log", "/data/audit.jsonl", "chain file")
		fs.Parse(args)
		f, err := os.Open(*path)
		if err != nil {
			log.Fatal(err)
		}
		w := os.Stdout
		// Prints up to the first broken line, then fails.
		_, err = chain.Verify(f, func(_ uint64, ev json.RawMessage) { w.Write(ev); w.Write([]byte("\n")) })
		if err != nil {
			log.Fatal(err)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		os.Exit(2)
	}
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := fs.String("listen", ":8443", "webhook address (mTLS)")
	metricsAddr := fs.String("metrics", ":9090", "metrics and health address")
	path := fs.String("log", "/data/audit.jsonl", "chain file")
	certFile := fs.String("cert", "/tls/tls.crt", "serving certificate")
	keyFile := fs.String("key", "/tls/tls.key", "serving key")
	caFile := fs.String("client-ca", "/tls/ca.crt", "CA of the API server's client certificate")
	clientName := fs.String("client-name", "kube-apiserver-audit", "required common name of the client certificate")
	every := fs.Duration("check-every", 30*time.Second, "how often to re-read and verify the chain")
	fs.Parse(args)

	l, err := chain.Open(*path)
	switch {
	case chain.IsBroken(err):
		// Keep receiving: new events are still evidence. The broken chain
		// stays on disk and every check reports it.
		log.Printf("CHAIN BROKEN at open: %v; appending after entry %d", err, l.State().Entries)
	case err != nil:
		log.Fatalf("open %s: %v", *path, err)
	default:
		st := l.State()
		log.Printf("chain verified at open: entries=%d head=%s", st.Entries, st.Head)
	}
	defer l.Close()
	chainEntries.Set(float64(l.State().Entries))
	check(l, err == nil)

	ca, err := os.ReadFile(*caFile)
	if err != nil {
		log.Fatal(err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		log.Fatalf("no certificates in %s", *caFile)
	}
	cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		log.Fatal(err)
	}
	tlsConfig := &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
		// The sink's CA signs only this sink's certificate and the API
		// server's client certificate; check the name anyway, so a
		// server certificate can't be used as a client.
		VerifyPeerCertificate: func(_ [][]byte, chains [][]*x509.Certificate) error {
			if len(chains) == 0 || chains[0][0].Subject.CommonName != *clientName {
				return errors.New("client is not the API server")
			}
			return nil
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /audit", func(w http.ResponseWriter, r *http.Request) { receive(l, w, r) })
	srv := &http.Server{Addr: *listen, Handler: mux, TLSConfig: tlsConfig,
		ReadHeaderTimeout: 10 * time.Second, ReadTimeout: time.Minute}

	mmux := http.NewServeMux()
	mmux.Handle("GET /metrics", promhttp.Handler())
	mmux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	msrv := &http.Server{Addr: *metricsAddr, Handler: mmux, ReadHeaderTimeout: 10 * time.Second}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		t := time.NewTicker(*every)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				check(l, true)
			}
		}
	}()
	go func() {
		if err := msrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	go func() {
		log.Printf("receiving audit events on %s, chain %s", *listen, *path)
		if err := srv.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()
	<-ctx.Done()
	sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	srv.Shutdown(sctx)
	msrv.Shutdown(sctx)
}

var lastLogged chain.State

// check re-reads the chain and compares it with what was written. A
// passing check logs the head when it has moved: the pod's log is a
// second record of the chain's length and head, outside its volume.
func check(l *chain.Log, openedClean bool) {
	st, err := l.Check()
	chainChecked.SetToCurrentTime()
	if err != nil || !openedClean {
		chainVerified.Set(0)
		if err != nil {
			log.Printf("CHAIN CHECK FAILED: %v", err)
		}
		return
	}
	chainVerified.Set(1)
	if st != lastLogged {
		log.Printf("chain head: entries=%d head=%s", st.Entries, st.Head)
		lastLogged = st
	}
}

// receive takes one batch: an audit.k8s.io/v1 EventList. The batch is on
// disk before the answer, so a 200 means stored; on any error the API
// server sends the batch again.
func receive(l *chain.Log, w http.ResponseWriter, r *http.Request) {
	var list struct {
		Kind  string            `json:"kind"`
		Items []json.RawMessage `json:"items"`
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<20))
	if err == nil {
		err = json.Unmarshal(body, &list)
	}
	if err == nil && list.Kind != "EventList" {
		err = fmt.Errorf("kind %q, want EventList", list.Kind)
	}
	if err != nil {
		batchesTotal.WithLabelValues("rejected").Inc()
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	parsed := make([]events.Event, len(list.Items))
	for i, raw := range list.Items {
		if parsed[i], err = events.Parse(raw); err != nil {
			batchesTotal.WithLabelValues("rejected").Inc()
			http.Error(w, fmt.Sprintf("item %d: %v", i, err), http.StatusBadRequest)
			return
		}
	}
	if err := l.Append(list.Items); err != nil {
		batchesTotal.WithLabelValues("write_error").Inc()
		log.Printf("append: %v", err)
		http.Error(w, "not stored", http.StatusInternalServerError)
		return
	}
	batchesTotal.WithLabelValues("ok").Inc()
	chainEntries.Set(float64(l.State().Entries))
	for _, e := range parsed {
		if !e.Final() {
			continue
		}
		eventsTotal.WithLabelValues(e.Actor(), e.Outcome()).Inc()
		if c := e.Change(); c != "" {
			changesTotal.WithLabelValues(c, e.Actor()).Inc()
		}
	}
	w.WriteHeader(http.StatusOK)
}
