---
name: resilience-patterns
description: Patterns for building resilient distributed systems
category: architecture/distributed-systems
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Resilience Patterns

## Overview

Resilience patterns help systems handle failures gracefully, recover quickly,
and continue operating under adverse conditions. These patterns are essential
for distributed systems where partial failures are inevitable.

## Circuit Breaker

```go
package resilience

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// CircuitState is the operational state of a circuit breaker.
type CircuitState int

const (
	StateClosed   CircuitState = iota // Normal operation
	StateOpen                         // Failing, reject requests
	StateHalfOpen                     // Testing recovery
)

func (s CircuitState) String() string {
	switch s {
	case StateClosed:
		return "CLOSED"
	case StateOpen:
		return "OPEN"
	case StateHalfOpen:
		return "HALF_OPEN"
	default:
		return "UNKNOWN"
	}
}

// ErrCircuitOpen is returned when the breaker rejects a call because it is open.
var ErrCircuitOpen = errors.New("circuit breaker is open")

// CircuitBreakerConfig tunes when the breaker opens and closes.
type CircuitBreakerConfig struct {
	FailureThreshold int           // Failures before opening
	SuccessThreshold int           // Successes to close from half-open
	Timeout          time.Duration // Time in open state before half-open
	VolumeThreshold  int           // Min requests before evaluating
}

// CircuitMetrics is a snapshot of the breaker's counters.
type CircuitMetrics struct {
	State        CircuitState
	Failures     int
	Successes    int
	RequestCount int
}

// CircuitBreaker guards a call site, tripping open when failures pile up.
type CircuitBreaker struct {
	cfg CircuitBreakerConfig

	mu              sync.Mutex
	state           CircuitState
	failures        int
	successes       int
	requestCount    int
	lastFailureTime time.Time
}

// NewCircuitBreaker returns a breaker in the closed state.
func NewCircuitBreaker(cfg CircuitBreakerConfig) *CircuitBreaker {
	return &CircuitBreaker{cfg: cfg, state: StateClosed}
}

// Execute runs fn if the breaker allows it, recording the outcome.
func (cb *CircuitBreaker) Execute(ctx context.Context, fn func(context.Context) error) error {
	if !cb.canExecute() {
		return ErrCircuitOpen
	}

	if err := fn(ctx); err != nil {
		cb.onFailure()
		return err
	}
	cb.onSuccess()
	return nil
}

func (cb *CircuitBreaker) canExecute() bool {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.requestCount++

	switch cb.state {
	case StateOpen:
		if time.Since(cb.lastFailureTime) < cb.cfg.Timeout {
			return false
		}
		cb.state = StateHalfOpen
		cb.successes = 0
		return true
	default: // StateClosed and StateHalfOpen both allow the call
		return true
	}
}

func (cb *CircuitBreaker) onSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures = 0
	if cb.state != StateHalfOpen {
		return
	}
	cb.successes++
	if cb.successes >= cb.cfg.SuccessThreshold {
		cb.state = StateClosed
	}
}

func (cb *CircuitBreaker) onFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()

	cb.failures++
	cb.lastFailureTime = time.Now()

	switch {
	case cb.state == StateHalfOpen:
		cb.state = StateOpen
	case cb.requestCount >= cb.cfg.VolumeThreshold && cb.failures >= cb.cfg.FailureThreshold:
		cb.state = StateOpen
	}
}

// State returns the current circuit state.
func (cb *CircuitBreaker) State() CircuitState {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return cb.state
}

// Metrics returns a snapshot of the breaker's counters.
func (cb *CircuitBreaker) Metrics() CircuitMetrics {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	return CircuitMetrics{
		State:        cb.state,
		Failures:     cb.failures,
		Successes:    cb.successes,
		RequestCount: cb.requestCount,
	}
}

// Usage
func callExternalService(ctx context.Context, cb *CircuitBreaker, client *http.Client) (*http.Response, error) {
	var resp *http.Response
	err := cb.Execute(ctx, func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.example.com/data", nil)
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		resp, err = client.Do(req)
		if err != nil {
			return fmt.Errorf("call external service: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}
```

## Retry with Backoff

```go
package resilience

import (
	"context"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"net"
	"time"
)

// RetryConfig tunes the retry loop.
type RetryConfig struct {
	MaxRetries        int
	InitialDelay      time.Duration
	MaxDelay          time.Duration
	BackoffMultiplier float64
	// Retryable reports whether an error is worth retrying. If nil, a default
	// network/5xx classifier is used.
	Retryable func(error) bool
}

// RetryPolicy runs a function with exponential backoff and jitter.
type RetryPolicy struct {
	cfg RetryConfig
}

// NewRetryPolicy returns a policy configured by cfg.
func NewRetryPolicy(cfg RetryConfig) *RetryPolicy {
	return &RetryPolicy{cfg: cfg}
}

// Execute calls fn, retrying transient failures until success, until ctx is
// cancelled, or until the retry budget is exhausted.
func (p *RetryPolicy) Execute(ctx context.Context, fn func(context.Context) error) error {
	var lastErr error

	for attempt := 0; attempt <= p.cfg.MaxRetries; attempt++ {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("retry aborted: %w", err)
		}

		lastErr = fn(ctx)
		if lastErr == nil {
			return nil
		}
		if !p.shouldRetry(lastErr, attempt) {
			return lastErr
		}

		select {
		case <-time.After(p.backoff(attempt)):
		case <-ctx.Done():
			return fmt.Errorf("retry aborted after attempt %d: %w", attempt, ctx.Err())
		}
	}

	return fmt.Errorf("all %d retries failed: %w", p.cfg.MaxRetries, lastErr)
}

func (p *RetryPolicy) shouldRetry(err error, attempt int) bool {
	if attempt >= p.cfg.MaxRetries {
		return false
	}
	if p.cfg.Retryable != nil {
		return p.cfg.Retryable(err)
	}
	return isRetryable(err)
}

// StatusError carries an HTTP status so retry logic can classify it.
type StatusError struct {
	StatusCode int
	Err        error
}

func (e *StatusError) Error() string { return fmt.Sprintf("status %d: %v", e.StatusCode, e.Err) }
func (e *StatusError) Unwrap() error { return e.Err }

// isRetryable retries network and server errors by default.
func isRetryable(err error) bool {
	var statusErr *StatusError
	if !errors.As(err, &statusErr) {
		return false
	}
	switch statusErr.StatusCode {
	case 408, 429, 500, 502, 503, 504:
		return true
	default:
		return false
	}
}

func (p *RetryPolicy) backoff(attempt int) time.Duration {
	delay := float64(p.cfg.InitialDelay) * math.Pow(p.cfg.BackoffMultiplier, float64(attempt))
	jitter := rand.Float64() * delay * 0.1 // 10% jitter
	total := time.Duration(delay + jitter)
	if total > p.cfg.MaxDelay {
		return p.cfg.MaxDelay
	}
	return total
}

// APIClient is the small consumer-side interface this call depends on.
type APIClient interface {
	FetchData(ctx context.Context) (Data, error)
}

// Usage: exponential backoff with jitter.
func fetchData(ctx context.Context, client APIClient) (Data, error) {
	policy := NewRetryPolicy(RetryConfig{
		MaxRetries:        3,
		InitialDelay:      time.Second,
		MaxDelay:          30 * time.Second,
		BackoffMultiplier: 2,
		Retryable: func(err error) bool {
			var netErr net.Error
			if errors.As(err, &netErr) {
				return true
			}
			return isRetryable(err)
		},
	})

	var data Data
	err := policy.Execute(ctx, func(ctx context.Context) error {
		var err error
		data, err = client.FetchData(ctx)
		return err
	})
	if err != nil {
		return Data{}, fmt.Errorf("fetch data: %w", err)
	}
	return data, nil
}
```

## Bulkhead (Isolation)

```go
package resilience

import (
	"context"
	"errors"
	"fmt"
)

// Bulkhead caps the number of concurrent operations to isolate resource use.
// A buffered channel is the idiomatic Go counting semaphore.
type Bulkhead struct {
	maxConcurrent int
	permits       chan struct{}
}

// NewBulkhead returns a bulkhead allowing maxConcurrent simultaneous calls.
func NewBulkhead(maxConcurrent int) *Bulkhead {
	return &Bulkhead{
		maxConcurrent: maxConcurrent,
		permits:       make(chan struct{}, maxConcurrent),
	}
}

// Execute runs fn once a permit is available, blocking (or returning when ctx
// is done) while the bulkhead is full.
func (b *Bulkhead) Execute(ctx context.Context, fn func(context.Context) error) error {
	select {
	case b.permits <- struct{}{}:
	case <-ctx.Done():
		return fmt.Errorf("bulkhead acquire: %w", ctx.Err())
	}
	defer func() { <-b.permits }()

	return fn(ctx)
}

// ErrBulkheadFull is returned when a non-blocking bulkhead has no free permit.
var ErrBulkheadFull = errors.New("bulkhead queue is full")

// TryExecute runs fn only if a permit is immediately available; otherwise it
// returns ErrBulkheadFull instead of blocking. This models the thread-pool
// bulkhead's bounded-queue rejection.
func (b *Bulkhead) TryExecute(ctx context.Context, fn func(context.Context) error) error {
	select {
	case b.permits <- struct{}{}:
	default:
		return ErrBulkheadFull
	}
	defer func() { <-b.permits }()

	return fn(ctx)
}

// BulkheadMetrics is a snapshot of a bulkhead's saturation.
type BulkheadMetrics struct {
	AvailablePermits int
	MaxConcurrent    int
	InUse            int
}

// Metrics returns a snapshot of permit usage.
func (b *Bulkhead) Metrics() BulkheadMetrics {
	inUse := len(b.permits)
	return BulkheadMetrics{
		AvailablePermits: b.maxConcurrent - inUse,
		MaxConcurrent:    b.maxConcurrent,
		InUse:            inUse,
	}
}

// ResilientService isolates unrelated operations behind separate bulkheads so
// that one saturated dependency cannot starve the others.
type ResilientService struct {
	database    *Bulkhead
	externalAPI *Bulkhead
	cache       *Bulkhead
}

// NewResilientService wires a bulkhead per dependency class.
func NewResilientService() *ResilientService {
	return &ResilientService{
		database:    NewBulkhead(10),
		externalAPI: NewBulkhead(5),
		cache:       NewBulkhead(20),
	}
}

// QueryDatabase runs a database call inside the database bulkhead.
func (s *ResilientService) QueryDatabase(ctx context.Context, query func(context.Context) error) error {
	return s.database.Execute(ctx, query)
}

// CallExternalAPI runs an outbound call inside the external-api bulkhead.
func (s *ResilientService) CallExternalAPI(ctx context.Context, request func(context.Context) error) error {
	return s.externalAPI.Execute(ctx, request)
}

// AccessCache runs a cache operation inside the cache bulkhead.
func (s *ResilientService) AccessCache(ctx context.Context, operation func(context.Context) error) error {
	return s.cache.Execute(ctx, operation)
}
```

## Timeout

```go
package resilience

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"
)

// TimeoutPolicy bounds how long an operation may run using a derived context.
// Go needs no separate cancellation type: the context that carries the
// deadline is the same one that cancels the in-flight work.
type TimeoutPolicy struct {
	timeout time.Duration
}

// NewTimeoutPolicy returns a policy that cancels operations after timeout.
func NewTimeoutPolicy(timeout time.Duration) *TimeoutPolicy {
	return &TimeoutPolicy{timeout: timeout}
}

// Execute runs fn with a context cancelled after the policy's timeout, and
// distinguishes a timeout from an upstream cancellation for the caller.
func (p *TimeoutPolicy) Execute(ctx context.Context, fn func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()

	err := fn(ctx)
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("operation timed out after %s: %w", p.timeout, err)
	case errors.Is(err, context.Canceled):
		return fmt.Errorf("operation cancelled: %w", err)
	default:
		return err
	}
}

// Usage: the derived context carries the deadline into the HTTP call, which
// aborts the in-flight request when the deadline trips.
func fetchWithTimeout(ctx context.Context, client *http.Client) (*http.Response, error) {
	policy := NewTimeoutPolicy(5 * time.Second)

	var resp *http.Response
	err := policy.Execute(ctx, func(ctx context.Context) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.example.com/data", nil)
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		resp, err = client.Do(req)
		if err != nil {
			return fmt.Errorf("do request: %w", err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}
```

## Fallback

```go
package resilience

import (
	"context"
	"fmt"
)

// FallbackPolicy runs a primary function and falls back to an alternative when
// the primary fails (and ShouldFallback, if set, approves the error).
type FallbackPolicy[T any] struct {
	Primary        func(context.Context) (T, error)
	Fallback       func(context.Context) (T, error)
	ShouldFallback func(error) bool
}

// Execute runs the primary, falling back on qualifying errors.
func (p FallbackPolicy[T]) Execute(ctx context.Context) (T, error) {
	result, err := p.Primary(ctx)
	if err == nil {
		return result, nil
	}
	if p.ShouldFallback != nil && !p.ShouldFallback(err) {
		return result, err
	}
	return p.Fallback(ctx)
}

// Cache is the small consumer-side interface the fallback needs.
type Cache[T any] interface {
	Get(ctx context.Context, key string) (value T, ok bool, err error)
	Set(ctx context.Context, key string, value T) error
}

// CacheFallback serves the last cached value when the primary source fails.
type CacheFallback[T any] struct {
	cache   Cache[T]
	primary func(context.Context) (T, error)
	key     string
}

// NewCacheFallback wires a cache-backed fallback for a given key.
func NewCacheFallback[T any](cache Cache[T], key string, primary func(context.Context) (T, error)) *CacheFallback[T] {
	return &CacheFallback[T]{cache: cache, primary: primary, key: key}
}

// Execute refreshes the cache on success, or serves the last cached value on
// failure when one exists.
func (f *CacheFallback[T]) Execute(ctx context.Context) (T, error) {
	result, err := f.primary(ctx)
	if err == nil {
		if setErr := f.cache.Set(ctx, f.key, result); setErr != nil {
			return result, fmt.Errorf("cache set: %w", setErr)
		}
		return result, nil
	}

	cached, ok, getErr := f.cache.Get(ctx, f.key)
	if getErr != nil {
		return result, fmt.Errorf("cache get after primary failure (%v): %w", err, getErr)
	}
	if ok {
		return cached, nil
	}
	return result, err
}

// MLService and ProductService are the small dependencies degraded through.
type MLService interface {
	PersonalizedRecommendations(ctx context.Context, userID string) ([]Recommendation, error)
}

type ProductService interface {
	PopularItems(ctx context.Context) ([]Recommendation, error)
}

// GracefulDegradation degrades through progressively cheaper sources.
type GracefulDegradation struct {
	ml       MLService
	products ProductService
}

// GetProductRecommendations tries personalized results, then popular items,
// then static defaults, so a caller always receives a usable answer.
func (g *GracefulDegradation) GetProductRecommendations(ctx context.Context, userID string) []Recommendation {
	if recs, err := g.ml.PersonalizedRecommendations(ctx, userID); err == nil {
		return recs
	}
	if popular, err := g.products.PopularItems(ctx); err == nil {
		return popular
	}
	return defaultRecommendations()
}
```

## Rate Limiting

```go
package resilience

import (
	"fmt"
	"net/http"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Token bucket: prefer the standard golang.org/x/time/rate.Limiter over
// hand-rolled refill math. A Limiter with rate r and burst b behaves as a
// bucket of capacity b that refills r tokens per second.
func newTokenBucket(refillPerSecond float64, capacity int) *rate.Limiter {
	return rate.NewLimiter(rate.Limit(refillPerSecond), capacity)
}

// tryAcquire takes n tokens without blocking, reporting whether they were free.
func tryAcquire(limiter *rate.Limiter, n int) bool {
	return limiter.AllowN(time.Now(), n)
}

// SlidingWindowRateLimiter caps requests per key within a rolling time window.
type SlidingWindowRateLimiter struct {
	window      time.Duration
	maxRequests int

	mu       sync.Mutex
	requests map[string][]time.Time
}

// NewSlidingWindowRateLimiter allows maxRequests per key within window.
func NewSlidingWindowRateLimiter(window time.Duration, maxRequests int) *SlidingWindowRateLimiter {
	return &SlidingWindowRateLimiter{
		window:      window,
		maxRequests: maxRequests,
		requests:    make(map[string][]time.Time),
	}
}

// Allow reports whether a request for key fits within the current window,
// recording it when it does.
func (l *SlidingWindowRateLimiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-l.window)
	kept := prune(l.requests[key], cutoff)

	if len(kept) >= l.maxRequests {
		l.requests[key] = kept
		return false
	}

	l.requests[key] = append(kept, time.Now())
	return true
}

// Remaining reports how many requests key may still make in the window.
func (l *SlidingWindowRateLimiter) Remaining(key string) int {
	l.mu.Lock()
	defer l.mu.Unlock()

	cutoff := time.Now().Add(-l.window)
	kept := prune(l.requests[key], cutoff)
	l.requests[key] = kept

	remaining := l.maxRequests - len(kept)
	if remaining < 0 {
		return 0
	}
	return remaining
}

// prune drops timestamps at or before cutoff, reusing the backing array.
func prune(timestamps []time.Time, cutoff time.Time) []time.Time {
	kept := timestamps[:0]
	for _, t := range timestamps {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	return kept
}

// RateLimitMiddleware rejects requests from clients that exceed the limiter.
func RateLimitMiddleware(limiter *SlidingWindowRateLimiter, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := clientKey(r)

		if !limiter.Allow(key) {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "Too many requests", http.StatusTooManyRequests)
			return
		}

		w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", limiter.Remaining(key)))
		next.ServeHTTP(w, r)
	})
}

func clientKey(r *http.Request) string {
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		return fwd
	}
	return r.RemoteAddr
}
```

## Health Checks

```go
package resilience

import (
	"context"
	"database/sql"
	"net/http"
	"sync"
	"time"
)

// HealthState is the outcome of a single health check.
type HealthState string

const (
	StatusHealthy   HealthState = "healthy"
	StatusUnhealthy HealthState = "unhealthy"
	StatusDegraded  HealthState = "degraded"
)

// HealthStatus reports the result of one check.
type HealthStatus struct {
	Status   HealthState
	Details  map[string]any
	Duration time.Duration
}

// HealthCheck is the small interface each dependency probe implements.
type HealthCheck interface {
	Name() string
	Check(ctx context.Context) HealthStatus
}

// SystemHealth aggregates every registered check.
type SystemHealth struct {
	Status HealthState
	Checks map[string]HealthStatus
}

// HealthCheckRegistry runs a set of checks and rolls their results up.
type HealthCheckRegistry struct {
	checks []HealthCheck
}

// Register adds a check to the registry.
func (r *HealthCheckRegistry) Register(check HealthCheck) {
	r.checks = append(r.checks, check)
}

// CheckAll runs every check concurrently and derives an overall status.
func (r *HealthCheckRegistry) CheckAll(ctx context.Context) SystemHealth {
	results := make(map[string]HealthStatus, len(r.checks))
	var mu sync.Mutex
	var wg sync.WaitGroup

	for _, check := range r.checks {
		wg.Add(1)
		go func(check HealthCheck) {
			defer wg.Done()

			start := time.Now()
			status := check.Check(ctx)
			status.Duration = time.Since(start)

			mu.Lock()
			results[check.Name()] = status
			mu.Unlock()
		}(check)
	}
	wg.Wait()

	return SystemHealth{Status: overallStatus(results), Checks: results}
}

func overallStatus(results map[string]HealthStatus) HealthState {
	overall := StatusHealthy
	for _, status := range results {
		switch status.Status {
		case StatusUnhealthy:
			return StatusUnhealthy
		case StatusDegraded:
			overall = StatusDegraded
		}
	}
	return overall
}

// DatabaseHealthCheck probes a SQL database with a trivial query.
type DatabaseHealthCheck struct {
	db *sql.DB
}

// Name identifies the check.
func (c *DatabaseHealthCheck) Name() string { return "database" }

// Check pings the database.
func (c *DatabaseHealthCheck) Check(ctx context.Context) HealthStatus {
	if err := c.db.PingContext(ctx); err != nil {
		return HealthStatus{Status: StatusUnhealthy, Details: map[string]any{"error": err.Error()}}
	}
	return HealthStatus{Status: StatusHealthy}
}

// ExternalServiceHealthCheck probes a downstream service's /health endpoint.
type ExternalServiceHealthCheck struct {
	serviceURL string
	client     *http.Client
}

// NewExternalServiceHealthCheck builds a check with a bounded HTTP timeout.
func NewExternalServiceHealthCheck(serviceURL string, timeout time.Duration) *ExternalServiceHealthCheck {
	return &ExternalServiceHealthCheck{
		serviceURL: serviceURL,
		client:     &http.Client{Timeout: timeout},
	}
}

// Name identifies the check.
func (c *ExternalServiceHealthCheck) Name() string { return "external-api" }

// Check calls the downstream health endpoint.
func (c *ExternalServiceHealthCheck) Check(ctx context.Context) HealthStatus {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.serviceURL+"/health", nil)
	if err != nil {
		return HealthStatus{Status: StatusUnhealthy, Details: map[string]any{"error": err.Error()}}
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return HealthStatus{Status: StatusUnhealthy, Details: map[string]any{"error": err.Error()}}
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return HealthStatus{Status: StatusHealthy}
	}
	return HealthStatus{Status: StatusDegraded, Details: map[string]any{"statusCode": resp.StatusCode}}
}

// KubernetesHealthChecks exposes liveness and readiness probes.
type KubernetesHealthChecks struct {
	registry *HealthCheckRegistry
}

// LivenessCheck answers "is the process running?": if it can respond, it is.
func (k *KubernetesHealthChecks) LivenessCheck() HealthStatus {
	return HealthStatus{Status: StatusHealthy}
}

// ReadinessCheck answers "can the process serve traffic?" by checking deps.
func (k *KubernetesHealthChecks) ReadinessCheck(ctx context.Context) SystemHealth {
	return k.registry.CheckAll(ctx)
}
```

## Combined Resilience Policy

```go
package resilience

import (
	"context"
	"fmt"
	"time"
)

// Op is the unit of work every resilience policy wraps.
type Op func(context.Context) error

// middleware wraps an Op with one policy's behavior.
type middleware func(Op) Op

// ResiliencePolicy composes resilience patterns into a single Op wrapper.
type ResiliencePolicy struct {
	middlewares []middleware
}

// NewResiliencePolicy returns an empty policy to build on.
func NewResiliencePolicy() *ResiliencePolicy {
	return &ResiliencePolicy{}
}

// WithTimeout bounds each attempt to the given duration.
func (p *ResiliencePolicy) WithTimeout(timeout time.Duration) *ResiliencePolicy {
	policy := NewTimeoutPolicy(timeout)
	p.middlewares = append(p.middlewares, func(next Op) Op {
		return func(ctx context.Context) error { return policy.Execute(ctx, next) }
	})
	return p
}

// WithRetry retries transient failures.
func (p *ResiliencePolicy) WithRetry(cfg RetryConfig) *ResiliencePolicy {
	policy := NewRetryPolicy(cfg)
	p.middlewares = append(p.middlewares, func(next Op) Op {
		return func(ctx context.Context) error { return policy.Execute(ctx, next) }
	})
	return p
}

// WithCircuitBreaker trips open under sustained failure.
func (p *ResiliencePolicy) WithCircuitBreaker(cfg CircuitBreakerConfig) *ResiliencePolicy {
	breaker := NewCircuitBreaker(cfg)
	p.middlewares = append(p.middlewares, func(next Op) Op {
		return func(ctx context.Context) error { return breaker.Execute(ctx, next) }
	})
	return p
}

// WithBulkhead caps concurrency.
func (p *ResiliencePolicy) WithBulkhead(maxConcurrent int) *ResiliencePolicy {
	bulkhead := NewBulkhead(maxConcurrent)
	p.middlewares = append(p.middlewares, func(next Op) Op {
		return func(ctx context.Context) error { return bulkhead.Execute(ctx, next) }
	})
	return p
}

// WithFallback runs fallback when the wrapped Op fails.
func (p *ResiliencePolicy) WithFallback(fallback Op) *ResiliencePolicy {
	p.middlewares = append(p.middlewares, func(next Op) Op {
		return func(ctx context.Context) error {
			if err := next(ctx); err != nil {
				return fallback(ctx)
			}
			return nil
		}
	})
	return p
}

// Execute applies the policies around fn: the first registered is outermost,
// the last (typically the fallback) is innermost, closest to fn.
func (p *ResiliencePolicy) Execute(ctx context.Context, fn Op) error {
	wrapped := fn
	for i := len(p.middlewares) - 1; i >= 0; i-- {
		wrapped = p.middlewares[i](wrapped)
	}
	return wrapped(ctx)
}

// UserService is the small consumer-side interface this call depends on.
type UserService interface {
	GetUser(ctx context.Context, userID string) (User, error)
}

// Usage
func loadUser(ctx context.Context, users UserService, userID string) (User, error) {
	var user User

	policy := NewResiliencePolicy().
		WithTimeout(5 * time.Second).
		WithRetry(RetryConfig{MaxRetries: 3, InitialDelay: time.Second, MaxDelay: 10 * time.Second, BackoffMultiplier: 2}).
		WithCircuitBreaker(CircuitBreakerConfig{FailureThreshold: 5, SuccessThreshold: 3, Timeout: 30 * time.Second, VolumeThreshold: 10}).
		WithBulkhead(10).
		WithFallback(func(ctx context.Context) error {
			user = User{Name: "Guest"}
			return nil
		})

	err := policy.Execute(ctx, func(ctx context.Context) error {
		var err error
		user, err = users.GetUser(ctx, userID)
		return err
	})
	if err != nil {
		return User{}, fmt.Errorf("load user %s: %w", userID, err)
	}
	return user, nil
}
```

## Benefits

| Pattern | Protection Against | Trade-off |
|---------|-------------------|-----------|
| Circuit Breaker | Cascading failures | May reject valid requests |
| Retry | Transient failures | Increased latency |
| Bulkhead | Resource exhaustion | Limited throughput |
| Timeout | Hanging requests | May cut off valid operations |
| Fallback | Complete failure | Degraded functionality |
| Rate Limiting | Overload | Request rejection |

## When to Use

- **Circuit Breaker**: External service calls, database connections
- **Retry**: Network requests, distributed operations
- **Bulkhead**: Isolating critical from non-critical operations
- **Timeout**: Any I/O operation with uncertain latency
- **Fallback**: When degraded operation is acceptable
- **Rate Limiting**: Public APIs, shared resources
