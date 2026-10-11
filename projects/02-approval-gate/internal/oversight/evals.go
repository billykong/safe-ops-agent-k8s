package oversight

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Quality next to throughput (P4-22): the latest replay eval's result, as
// the evaluator recorded it. EvalRuns (P4-12, projects/04-observability)
// are written once and only by the evaluator's identity, so neither the
// agent nor its own telemetry can raise these numbers.

// EvalRun is the part of an EvalRun the metrics use.
type EvalRun struct {
	Name          string
	Finished      time.Time
	Total, Passed int
	Disagreements int
	SafetyHeld    bool
	Scenarios     []EvalScenario
}

type EvalScenario struct {
	ID                 string
	Passed, SafetyHeld bool
}

// ParseEvalRun reads an EvalRun from its unstructured form. The CRD's
// schema validated it; a missing field reads as zero.
func ParseEvalRun(u unstructured.Unstructured) EvalRun {
	r := EvalRun{Name: u.GetName()}
	fin, _, _ := unstructured.NestedString(u.Object, "spec", "finishedAt")
	r.Finished, _ = time.Parse(time.RFC3339, fin)
	n := func(f ...string) int {
		v, _, _ := unstructured.NestedInt64(u.Object, append([]string{"spec", "summary"}, f...)...)
		return int(v)
	}
	r.Total, r.Passed, r.Disagreements = n("total"), n("passed"), n("disagreements")
	held, _, _ := unstructured.NestedString(u.Object, "spec", "summary", "safetyHeld")
	r.SafetyHeld = held == "true"
	scs, _, _ := unstructured.NestedSlice(u.Object, "spec", "scenarios")
	for _, x := range scs {
		m, ok := x.(map[string]any)
		if !ok {
			continue
		}
		id, _, _ := unstructured.NestedString(m, "id")
		p, _, _ := unstructured.NestedBool(m, "passed")
		s, _, _ := unstructured.NestedBool(m, "safetyHeld")
		r.Scenarios = append(r.Scenarios, EvalScenario{ID: id, Passed: p, SafetyHeld: s})
	}
	return r
}

// Latest is the run that finished last; ok false with none.
func Latest(runs []EvalRun) (EvalRun, bool) {
	var best EvalRun
	for _, r := range runs {
		if r.Finished.After(best.Finished) || (r.Finished.Equal(best.Finished) && r.Name > best.Name) {
			best = r
		}
	}
	return best, len(runs) > 0
}

// EvalCollector exposes the latest EvalRun as Prometheus metrics, re-read
// on every scrape. List returns readable=false when EvalRuns can't be
// read (no CRD, no access), which is reported, not an error: the approval
// gate runs without the evals installed.
type EvalCollector struct {
	List func(context.Context) (runs []EvalRun, readable bool)

	readable, runs, finished, scenarios, safety, disagreements, scenario *prometheus.Desc
}

func NewEvalCollector(list func(context.Context) ([]EvalRun, bool)) *EvalCollector {
	d := func(name, help string, labels ...string) *prometheus.Desc {
		return prometheus.NewDesc(name, help, labels, nil)
	}
	return &EvalCollector{
		List:          list,
		readable:      d("safeops_eval_runs_readable", "1 if the controller can read EvalRuns."),
		runs:          d("safeops_eval_runs", "EvalRuns recorded."),
		finished:      d("safeops_eval_last_run_timestamp_seconds", "When the latest eval run finished.", "run"),
		scenarios:     d("safeops_eval_last_run_scenarios", "Scenarios in the latest eval run, by result.", "run", "result"),
		safety:        d("safeops_eval_last_run_safety_held", "1 if safety held in every scenario of the latest eval run.", "run"),
		disagreements: d("safeops_eval_last_run_judge_disagreements", "Scenarios where the judge and the deterministic checks disagreed.", "run"),
		scenario:      d("safeops_eval_scenario_passed", "1 if the scenario passed in the latest eval run.", "run", "scenario"),
	}
}

func (c *EvalCollector) Describe(ch chan<- *prometheus.Desc) {
	for _, d := range []*prometheus.Desc{c.readable, c.runs, c.finished, c.scenarios, c.safety, c.disagreements, c.scenario} {
		ch <- d
	}
}

func (c *EvalCollector) Collect(ch chan<- prometheus.Metric) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	runs, readable := c.List(ctx)
	g := func(d *prometheus.Desc, v float64, labels ...string) {
		ch <- prometheus.MustNewConstMetric(d, prometheus.GaugeValue, v, labels...)
	}
	g(c.readable, asFloat(readable))
	if !readable {
		return
	}
	g(c.runs, float64(len(runs)))
	r, ok := Latest(runs)
	if !ok {
		return
	}
	g(c.finished, float64(r.Finished.Unix()), r.Name)
	g(c.scenarios, float64(r.Passed), r.Name, "passed")
	g(c.scenarios, float64(r.Total-r.Passed), r.Name, "failed")
	g(c.safety, asFloat(r.SafetyHeld), r.Name)
	g(c.disagreements, float64(r.Disagreements), r.Name)
	for _, s := range r.Scenarios {
		g(c.scenario, asFloat(s.Passed), r.Name, s.ID)
	}
}

func asFloat(v bool) float64 {
	if v {
		return 1
	}
	return 0
}
