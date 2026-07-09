# Distributed Systems Reference

## Resilience Patterns

### Circuit Breaker

Prevents cascading failures by detecting failures and temporarily blocking requests.

```go
type CircuitState int

const (
	StateClosed   CircuitState = iota // normal operation
	StateOpen                         // failing, reject requests
	StateHalfOpen                     // testing recovery
)

type CircuitBreakerConfig struct {
	FailureThreshold int           // failures before opening
	SuccessThreshold int           // successes to close from half-open
	Timeout          time.Duration // time open before half-open
	VolumeThreshold  int           // min requests before evaluating
}

type CircuitBreaker struct {
	cfg             CircuitBreakerConfig
	mu              sync.Mutex
	state           CircuitState
	failures        int
	successes       int
	lastFailureTime time.Time
}

func NewCircuitBreaker(cfg CircuitBreakerConfig) *CircuitBreaker {
	return &CircuitBreaker{cfg: cfg, state: StateClosed}
}

var ErrCircuitOpen = errors.New("circuit breaker is open")

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
	if cb.state == StateOpen {
		if time.Since(cb.lastFailureTime) < cb.cfg.Timeout {
			return false
		}
		cb.state = StateHalfOpen
	}
	return true
}

func (cb *CircuitBreaker) onSuccess() {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.failures, cb.successes = 0, cb.successes+1
	if cb.state == StateHalfOpen && cb.successes >= cb.cfg.SuccessThreshold {
		cb.state, cb.successes = StateClosed, 0
	}
}

func (cb *CircuitBreaker) onFailure() {
	cb.mu.Lock()
	defer cb.mu.Unlock()
	cb.failures, cb.lastFailureTime = cb.failures+1, time.Now()
	if cb.failures >= cb.cfg.FailureThreshold {
		cb.state = StateOpen
	}
}

// Usage
func example(ctx context.Context, client *http.Client) error {
	cb := NewCircuitBreaker(CircuitBreakerConfig{
		FailureThreshold: 5,
		SuccessThreshold: 3,
		Timeout:          30 * time.Second,
		VolumeThreshold:  10,
	})
	return cb.Execute(ctx, func(ctx context.Context) error {
		_, err := getJSON(ctx, client, "/api/data", nil)
		return err
	})
}
```

### Retry with Exponential Backoff

```go
type RetryConfig struct {
	MaxRetries        int
	InitialDelay      time.Duration
	MaxDelay          time.Duration
	BackoffMultiplier float64
	Retryable         func(error) bool // nil => retry any error
}

type RetryPolicy struct{ cfg RetryConfig }

func NewRetryPolicy(cfg RetryConfig) *RetryPolicy { return &RetryPolicy{cfg: cfg} }

func (p *RetryPolicy) Execute(ctx context.Context, fn func(context.Context) error) error {
	var lastErr error
	for attempt := 0; attempt <= p.cfg.MaxRetries; attempt++ {
		lastErr = fn(ctx)
		if lastErr == nil {
			return nil
		}
		if p.cfg.Retryable != nil && !p.cfg.Retryable(lastErr) {
			return lastErr
		}
		if attempt == p.cfg.MaxRetries {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(p.delay(attempt)):
		}
	}
	return fmt.Errorf("retry exhausted after %d attempts: %w", p.cfg.MaxRetries+1, lastErr)
}

func (p *RetryPolicy) delay(attempt int) time.Duration {
	d := float64(p.cfg.InitialDelay) * math.Pow(p.cfg.BackoffMultiplier, float64(attempt))
	d += rand.Float64() * d * 0.1 // 10% jitter
	return min(time.Duration(d), p.cfg.MaxDelay)
}

// Usage
func example(ctx context.Context, api API) error {
	retry := NewRetryPolicy(RetryConfig{
		MaxRetries:        3,
		InitialDelay:      time.Second,
		MaxDelay:          30 * time.Second,
		BackoffMultiplier: 2,
	})
	return retry.Execute(ctx, func(ctx context.Context) error { return api.FetchData(ctx) })
}
```

### Bulkhead (Isolation)

```go
// A buffered channel is Go's natural semaphore.
type Bulkhead struct{ sem chan struct{} }

func NewBulkhead(maxConcurrent int) *Bulkhead {
	return &Bulkhead{sem: make(chan struct{}, maxConcurrent)}
}

func (b *Bulkhead) Execute(ctx context.Context, fn func(context.Context) error) error {
	select {
	case b.sem <- struct{}{}:
		defer func() { <-b.sem }()
	case <-ctx.Done():
		return ctx.Err()
	}
	return fn(ctx)
}

// Isolate different operation classes behind their own bulkheads.
type ResilientService struct {
	database    *Bulkhead
	externalAPI *Bulkhead
	cache       *Bulkhead
}

func NewResilientService() *ResilientService {
	return &ResilientService{
		database:    NewBulkhead(10),
		externalAPI: NewBulkhead(5),
		cache:       NewBulkhead(20),
	}
}

func (s *ResilientService) QueryDatabase(ctx context.Context, fn func(context.Context) error) error {
	return s.database.Execute(ctx, fn)
}

func (s *ResilientService) CallExternalAPI(ctx context.Context, fn func(context.Context) error) error {
	return s.externalAPI.Execute(ctx, fn)
}
```

### Timeout

```go
// Prefer context deadlines over racing goroutines.
type TimeoutPolicy struct{ timeout time.Duration }

func NewTimeoutPolicy(timeout time.Duration) *TimeoutPolicy { return &TimeoutPolicy{timeout: timeout} }

func (p *TimeoutPolicy) Execute(ctx context.Context, fn func(context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()
	if err := fn(ctx); err != nil {
		return fmt.Errorf("operation failed within %s: %w", p.timeout, err)
	}
	return nil
}

// The function receives the derived context and must honor cancellation:
//   req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
```

### Fallback

```go
type FallbackPolicy[T any] struct {
	primary  func(context.Context) (T, error)
	fallback func(context.Context) (T, error)
}

func NewFallbackPolicy[T any](primary, fallback func(context.Context) (T, error)) *FallbackPolicy[T] {
	return &FallbackPolicy[T]{primary: primary, fallback: fallback}
}

func (p *FallbackPolicy[T]) Execute(ctx context.Context) (T, error) {
	if v, err := p.primary(ctx); err == nil {
		return v, nil
	}
	return p.fallback(ctx)
}

// Graceful degradation — try progressively cheaper sources.
func (s *RecommendationService) Recommendations(ctx context.Context, userID string) ([]Recommendation, error) {
	if recs, err := s.ml.Personalized(ctx, userID); err == nil {
		return recs, nil
	}
	if recs, err := s.products.Popular(ctx); err == nil {
		return recs, nil
	}
	return s.staticDefaults(), nil
}
```

### Combined Policy

```go
// A resilience decorator wraps an operation with one concern.
type Decorator func(fn func(context.Context) error) func(context.Context) error

func WithTimeout(d time.Duration) Decorator {
	return func(fn func(context.Context) error) func(context.Context) error {
		return func(ctx context.Context) error { return NewTimeoutPolicy(d).Execute(ctx, fn) }
	}
}

func WithRetry(cfg RetryConfig) Decorator {
	return func(fn func(context.Context) error) func(context.Context) error {
		return func(ctx context.Context) error { return NewRetryPolicy(cfg).Execute(ctx, fn) }
	}
}

func WithCircuitBreaker(cfg CircuitBreakerConfig) Decorator {
	cb := NewCircuitBreaker(cfg)
	return func(fn func(context.Context) error) func(context.Context) error {
		return func(ctx context.Context) error { return cb.Execute(ctx, fn) }
	}
}

func WithBulkhead(maxConcurrent int) Decorator {
	b := NewBulkhead(maxConcurrent)
	return func(fn func(context.Context) error) func(context.Context) error {
		return func(ctx context.Context) error { return b.Execute(ctx, fn) }
	}
}

// Chain applies decorators outermost-first.
func Chain(fn func(context.Context) error, ds ...Decorator) func(context.Context) error {
	for i := len(ds) - 1; i >= 0; i-- {
		fn = ds[i](fn)
	}
	return fn
}

// Usage
func example(ctx context.Context, users UserService, userID string) error {
	op := Chain(
		func(ctx context.Context) error { _, err := users.GetUser(ctx, userID); return err },
		WithTimeout(5*time.Second),
		WithRetry(RetryConfig{MaxRetries: 3, InitialDelay: time.Second, MaxDelay: 10 * time.Second, BackoffMultiplier: 2}),
		WithCircuitBreaker(CircuitBreakerConfig{FailureThreshold: 5, SuccessThreshold: 3, Timeout: 30 * time.Second, VolumeThreshold: 10}),
		WithBulkhead(10),
	)
	return op(ctx)
}
```

## Communication Patterns

### Synchronous (REST/gRPC)

```go
type ProductServiceClient struct {
	http    *http.Client
	breaker *CircuitBreaker
	baseURL string
}

func NewProductServiceClient(baseURL string, breaker *CircuitBreaker) *ProductServiceClient {
	return &ProductServiceClient{http: http.DefaultClient, breaker: breaker, baseURL: baseURL}
}

func (c *ProductServiceClient) GetProduct(ctx context.Context, id string) (Product, error) {
	var p Product
	err := c.breaker.Execute(ctx, func(ctx context.Context) error {
		return getJSON(ctx, c.http, c.baseURL+"/products/"+id, &p)
	})
	if err != nil {
		return Product{}, fmt.Errorf("get product %s: %w", id, err)
	}
	return p, nil
}
```

### Asynchronous (Events/Messages)

```go
type MessageBroker interface {
	Publish(ctx context.Context, topic string, msg any) error
}

type OrderEventPublisher struct{ broker MessageBroker }

func NewOrderEventPublisher(broker MessageBroker) *OrderEventPublisher {
	return &OrderEventPublisher{broker: broker}
}

func (p *OrderEventPublisher) PublishOrderCreated(ctx context.Context, o *Order) error {
	evt := OrderCreatedEvent{
		OrderID:    o.ID(),
		CustomerID: o.CustomerID(),
		Items:      o.Items(),
		Total:      o.Total(),
		Timestamp:  time.Now().UTC(),
	}
	if err := p.broker.Publish(ctx, "order.created", evt); err != nil {
		return fmt.Errorf("publish order.created: %w", err)
	}
	return nil
}

// Consumer method wired to a subscription at startup.
type OrderEventsConsumer struct{ notifications NotificationService }

func (c *OrderEventsConsumer) OnOrderCreated(ctx context.Context, evt OrderCreatedEvent) error {
	if err := c.notifications.SendOrderConfirmation(ctx, evt); err != nil {
		return fmt.Errorf("send confirmation: %w", err)
	}
	return nil
}
```

## Consistency Patterns

### Saga Pattern

```go
type SagaStep[C any] struct {
	Name       string
	Execute    func(ctx context.Context, c *C) error
	Compensate func(ctx context.Context, c *C) error
}

type CreateOrderSaga struct{ steps []SagaStep[OrderContext] }

func NewCreateOrderSaga(inv InventoryService, pay PaymentService, orders OrderRepository) *CreateOrderSaga {
	return &CreateOrderSaga{steps: []SagaStep[OrderContext]{
		{
			Name: "reserve_inventory",
			Execute: func(ctx context.Context, c *OrderContext) (err error) {
				c.ReservationID, err = inv.Reserve(ctx, c.Items)
				return
			},
			Compensate: func(ctx context.Context, c *OrderContext) error { return inv.CancelReservation(ctx, c.ReservationID) },
		},
		{
			Name: "process_payment",
			Execute: func(ctx context.Context, c *OrderContext) (err error) {
				c.PaymentID, err = pay.Charge(ctx, c.CustomerID, c.Total)
				return
			},
			Compensate: func(ctx context.Context, c *OrderContext) error { return pay.Refund(ctx, c.PaymentID) },
		},
		{
			Name:       "confirm_order",
			Execute:    func(ctx context.Context, c *OrderContext) error { return orders.Confirm(ctx, c.OrderID) },
			Compensate: func(ctx context.Context, c *OrderContext) error { return orders.Cancel(ctx, c.OrderID) },
		},
	}}
}

func (s *CreateOrderSaga) Execute(ctx context.Context, cmd CreateOrderCommand) error {
	c := &OrderContext{CreateOrderCommand: cmd}
	var completed []SagaStep[OrderContext]
	for _, step := range s.steps {
		if err := step.Execute(ctx, c); err != nil {
			for i := len(completed) - 1; i >= 0; i-- { // compensate in reverse order
				if cerr := completed[i].Compensate(ctx, c); cerr != nil {
					slog.ErrorContext(ctx, "compensation failed", "step", completed[i].Name, "err", cerr)
				}
			}
			return fmt.Errorf("saga step %q: %w", step.Name, err)
		}
		completed = append(completed, step)
	}
	return nil
}
```

### Outbox Pattern

```go
// Write the event in the SAME transaction as the state change.
type OrderService struct{ db *sql.DB }

func NewOrderService(db *sql.DB) *OrderService { return &OrderService{db: db} }

func (s *OrderService) CreateOrder(ctx context.Context, dto CreateOrderDTO) (*Order, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck // no-op after Commit

	order, err := insertOrder(ctx, tx, dto)
	if err != nil {
		return nil, fmt.Errorf("insert order: %w", err)
	}

	payload, err := json.Marshal(order)
	if err != nil {
		return nil, fmt.Errorf("marshal order: %w", err)
	}
	if err := insertOutbox(ctx, tx, "Order", order.ID, "OrderCreated", payload); err != nil {
		return nil, fmt.Errorf("write outbox: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}
	return order, nil
}

// A separate worker relays outbox rows to the broker.
type OutboxProcessor struct {
	db     *sql.DB
	broker MessageBroker
}

func NewOutboxProcessor(db *sql.DB, broker MessageBroker) *OutboxProcessor {
	return &OutboxProcessor{db: db, broker: broker}
}

func (p *OutboxProcessor) Process(ctx context.Context) error {
	messages, err := findUnpublished(ctx, p.db)
	if err != nil {
		return fmt.Errorf("load outbox: %w", err)
	}
	for _, m := range messages {
		if err := p.broker.Publish(ctx, m.EventType, m.Payload); err != nil {
			return fmt.Errorf("publish %s: %w", m.EventType, err)
		}
		if err := markPublished(ctx, p.db, m.ID); err != nil {
			return fmt.Errorf("mark published %s: %w", m.ID, err)
		}
	}
	return nil
}
```

## Health Checks

```go
type HealthStatus struct {
	Status   string         `json:"status"` // "healthy" | "unhealthy" | "degraded"
	Details  map[string]any `json:"details,omitempty"`
	Duration time.Duration  `json:"duration,omitempty"`
}

// Consumer-side interface: a named check that reports its health.
type HealthCheck interface {
	Name() string
	Check(ctx context.Context) HealthStatus
}

type HealthCheckRegistry struct {
	mu     sync.Mutex
	checks []HealthCheck
}

func NewHealthCheckRegistry() *HealthCheckRegistry { return &HealthCheckRegistry{} }

func (r *HealthCheckRegistry) Register(c HealthCheck) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.checks = append(r.checks, c)
}

func (r *HealthCheckRegistry) CheckAll(ctx context.Context) SystemHealth {
	results := make(map[string]HealthStatus, len(r.checks))
	overall := "healthy"
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, c := range r.checks {
		wg.Add(1)
		go func(c HealthCheck) {
			defer wg.Done()
			start := time.Now()
			st := c.Check(ctx)
			st.Duration = time.Since(start)
			mu.Lock()
			defer mu.Unlock()
			results[c.Name()] = st
			switch {
			case st.Status == "unhealthy":
				overall = "unhealthy"
			case st.Status == "degraded" && overall == "healthy":
				overall = "degraded"
			}
		}(c)
	}
	wg.Wait()
	return SystemHealth{Status: overall, Checks: results}
}

// Kubernetes liveness vs readiness.
type KubernetesHealthChecks struct{ registry *HealthCheckRegistry }

func (k *KubernetesHealthChecks) Liveness(ctx context.Context) HealthStatus {
	return HealthStatus{Status: "healthy"} // can we respond at all?
}

func (k *KubernetesHealthChecks) Readiness(ctx context.Context) SystemHealth {
	return k.registry.CheckAll(ctx) // can we serve traffic?
}
```

## Pattern Selection

| Pattern | Protection Against | Trade-off |
|---------|-------------------|-----------|
| Circuit Breaker | Cascading failures | May reject valid requests |
| Retry + Backoff | Transient failures | Increased latency |
| Bulkhead | Resource exhaustion | Limited throughput |
| Timeout | Hanging requests | May cut valid operations |
| Fallback | Complete failure | Degraded functionality |

## When to Use

| Scenario | Recommended Pattern |
|----------|-------------------|
| External service calls | Circuit Breaker + Retry |
| Database connections | Connection pooling + Timeout |
| Critical vs non-critical ops | Bulkhead isolation |
| Uncertain latency operations | Timeout |
| Acceptable degradation | Fallback |
| Distributed transactions | Saga |
| Message reliability | Outbox |
