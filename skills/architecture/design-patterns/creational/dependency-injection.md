---
name: dependency-injection
description: Dependency Injection pattern and IoC containers
category: architecture/design-patterns/creational
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Dependency Injection (DI)

## Overview

Dependency Injection is a technique where dependencies are provided to a
struct rather than created by the struct itself. It's a specific form of
Inversion of Control (IoC). In Go the default form is constructor injection:
pass dependencies as interfaces into `NewX`.

## Without DI vs With DI

```go
// ❌ Without DI — tight coupling
type OrderService struct {
	repository   *MySQLOrderRepository
	emailService *SendGridEmailService
	payment      *StripePaymentGateway
}

func NewOrderService() *OrderService {
	return &OrderService{
		repository:   NewMySQLOrderRepository(),
		emailService: NewSendGridEmailService(),
		payment:      NewStripePaymentGateway(),
	}
}

func (s *OrderService) CreateOrder(ctx context.Context, data CreateOrderParams) (*Order, error) {
	order, err := s.repository.Save(ctx, data)
	if err != nil {
		return nil, fmt.Errorf("save order: %w", err)
	}
	if err := s.emailService.Send(ctx, data.Email, "Order created"); err != nil {
		return nil, fmt.Errorf("send confirmation: %w", err)
	}
	if err := s.payment.Charge(ctx, data.Total); err != nil {
		return nil, fmt.Errorf("charge: %w", err)
	}
	return order, nil
}

// Problems:
// - Cannot switch implementations
// - Cannot substitute fakes for testing
// - The struct knows too much about its concrete dependencies

// ✅ With DI — loose coupling via small interfaces
type OrderService struct {
	repository OrderRepository
	email      EmailSender
	payment    PaymentGateway
}

func NewOrderService(repository OrderRepository, email EmailSender, payment PaymentGateway) *OrderService {
	return &OrderService{repository: repository, email: email, payment: payment}
}

func (s *OrderService) CreateOrder(ctx context.Context, data CreateOrderParams) (*Order, error) {
	order, err := s.repository.Save(ctx, data)
	if err != nil {
		return nil, fmt.Errorf("save order: %w", err)
	}
	if err := s.email.Send(ctx, data.Email, "Order created"); err != nil {
		return nil, fmt.Errorf("send confirmation: %w", err)
	}
	if err := s.payment.Charge(ctx, data.Total); err != nil {
		return nil, fmt.Errorf("charge: %w", err)
	}
	return order, nil
}
```

## Types of Injection

### Constructor Injection (Preferred)

```go
// Dependencies provided through the constructor.
type UserService struct {
	users  UserRepository
	hasher PasswordHasher
	logger Logger
}

func NewUserService(users UserRepository, hasher PasswordHasher, logger Logger) *UserService {
	return &UserService{users: users, hasher: hasher, logger: logger}
}

func (s *UserService) CreateUser(ctx context.Context, dto CreateUserParams) (*User, error) {
	s.logger.Log("Creating user")
	hashed, err := s.hasher.Hash(dto.Password)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}
	dto.Password = hashed
	user, err := s.users.Save(ctx, dto)
	if err != nil {
		return nil, fmt.Errorf("save user: %w", err)
	}
	return user, nil
}

// Usage
userService := NewUserService(
	NewPostgresUserRepository(db),
	NewBcryptPasswordHasher(),
	NewConsoleLogger(),
)
```

### Property/Setter Injection

```go
// Go rarely uses setter injection; when a dependency is genuinely optional,
// functional options are the idiomatic form.
type NotificationService struct {
	logger Logger
	email  EmailClient
}

type NotificationOption func(*NotificationService)

func WithLogger(logger Logger) NotificationOption {
	return func(s *NotificationService) { s.logger = logger }
}

func WithEmailClient(client EmailClient) NotificationOption {
	return func(s *NotificationService) { s.email = client }
}

func NewNotificationService(opts ...NotificationOption) *NotificationService {
	s := &NotificationService{logger: NopLogger{}}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *NotificationService) Notify(ctx context.Context, user User, message string) error {
	s.logger.Log(fmt.Sprintf("Notifying %s", user.Email))
	if err := s.email.Send(ctx, user.Email, message); err != nil {
		return fmt.Errorf("send notification: %w", err)
	}
	return nil
}

// Usage — optional dependencies configured at construction
service := NewNotificationService(
	WithLogger(NewConsoleLogger()),
	WithEmailClient(NewSendGridClient()),
)
```

### Method Injection

```go
// Dependencies passed to the specific method that needs them.
type ReportGenerator struct{}

func NewReportGenerator() *ReportGenerator {
	return &ReportGenerator{}
}

func (g *ReportGenerator) Generate(data ReportData, formatter ReportFormatter, exporter ReportExporter) ([]byte, error) {
	formatted := formatter.Format(data)
	out, err := exporter.Export(formatted)
	if err != nil {
		return nil, fmt.Errorf("export report: %w", err)
	}
	return out, nil
}

// Usage — different formatters for different calls
generator := NewReportGenerator()

// PDF report
pdfReport, err := generator.Generate(data, NewHTMLFormatter(), NewPDFExporter())
if err != nil {
	return fmt.Errorf("pdf report: %w", err)
}

// Excel report
excelReport, err := generator.Generate(data, NewTableFormatter(), NewExcelExporter())
if err != nil {
	return fmt.Errorf("excel report: %w", err)
}
```

## DI Containers

### google/wire (compile-time)

```go
//go:build wireinject

package main

import "github.com/google/wire"

// Providers describe how to build each dependency.
func provideUserRepository(db *sql.DB) UserRepository {
	return NewPostgresUserRepository(db)
}

func provideHasher() PasswordHasher {
	return NewBcryptPasswordHasher()
}

func provideLogger() Logger {
	return NewConsoleLogger()
}

// InitializeUserService is the injector; `wire` generates its real body into
// wire_gen.go at build time — no reflection, all errors caught by the compiler.
func InitializeUserService(db *sql.DB) (*UserService, error) {
	wire.Build(
		provideUserRepository,
		provideHasher,
		provideLogger,
		NewUserService,
	)
	return nil, nil // replaced by generated code
}

// Usage (against the generated wire_gen.go)
userService, err := InitializeUserService(db)
if err != nil {
	return fmt.Errorf("wire user service: %w", err)
}
```

### uber-go/dig (runtime container)

```go
import "go.uber.org/dig"

func buildContainer(db *sql.DB) *dig.Container {
	c := dig.New()
	_ = c.Provide(func() *sql.DB { return db })
	_ = c.Provide(func(db *sql.DB) UserRepository { return NewPostgresUserRepository(db) })
	_ = c.Provide(func() PasswordHasher { return NewBcryptPasswordHasher() })
	_ = c.Provide(func() Logger { return NewConsoleLogger() })
	_ = c.Provide(NewUserService)
	return c
}

// Resolve by asking for what you need — dig wires the graph at runtime.
func main() {
	c := buildContainer(db)
	err := c.Invoke(func(service *UserService) {
		// use service
		_ = service
	})
	if err != nil {
		log.Fatalf("resolve user service: %v", err)
	}
}
```

### samber/do (generics-based container)

```go
import "github.com/samber/do"

func main() {
	injector := do.New()

	do.Provide(injector, func(i *do.Injector) (UserRepository, error) {
		return NewPostgresUserRepository(do.MustInvoke[*sql.DB](i)), nil
	})
	do.Provide(injector, func(i *do.Injector) (PasswordHasher, error) {
		return NewBcryptPasswordHasher(), nil
	})
	do.Provide(injector, func(i *do.Injector) (Logger, error) {
		return NewConsoleLogger(), nil
	})
	do.Provide(injector, func(i *do.Injector) (*UserService, error) {
		return NewUserService(
			do.MustInvoke[UserRepository](i),
			do.MustInvoke[PasswordHasher](i),
			do.MustInvoke[Logger](i),
		), nil
	})

	// Auto-wiring — providers resolve on first use and are cached thereafter.
	userService := do.MustInvoke[*UserService](injector)
	_ = userService
}
```

## Scopes

```go
// Go DI libraries model lifetime explicitly rather than via scope keywords.

// Singleton — one instance for the whole process. samber/do caches every
// provider result, so an invoked service is effectively a singleton.
do.Provide(injector, func(i *do.Injector) (Logger, error) {
	return NewConsoleLogger(), nil
})
logger := do.MustInvoke[Logger](injector) // same instance on every invoke

// Transient — a fresh instance per call: use a plain constructor, not the container.
validator := NewRequestValidator()

// Request-scoped — build a child scope (or a fresh struct) per request.
func handle(parent *do.Injector, w http.ResponseWriter, r *http.Request) {
	scope := parent.Scope("request")
	defer scope.Shutdown()
	do.ProvideValue(scope, NewRequestContext(r))
	// resolve request-scoped services from scope
}
```

## Factory Pattern with DI

```go
// When you need runtime decisions.
type PaymentGatewayFactory interface {
	Create(kind PaymentType) (PaymentGateway, error)
}

type DefaultPaymentGatewayFactory struct {
	stripe PaymentGateway
	paypal PaymentGateway
}

func NewDefaultPaymentGatewayFactory(stripe, paypal PaymentGateway) *DefaultPaymentGatewayFactory {
	return &DefaultPaymentGatewayFactory{stripe: stripe, paypal: paypal}
}

func (f *DefaultPaymentGatewayFactory) Create(kind PaymentType) (PaymentGateway, error) {
	switch kind {
	case PaymentStripe:
		return f.stripe, nil
	case PaymentPayPal:
		return f.paypal, nil
	default:
		return nil, fmt.Errorf("unknown payment type: %d", kind)
	}
}

type OrderService struct {
	gateways PaymentGatewayFactory
}

func NewOrderService(gateways PaymentGatewayFactory) *OrderService {
	return &OrderService{gateways: gateways}
}

func (s *OrderService) ProcessPayment(ctx context.Context, order Order) error {
	gateway, err := s.gateways.Create(order.PaymentType)
	if err != nil {
		return fmt.Errorf("select gateway: %w", err)
	}
	if err := gateway.Charge(ctx, order.Total); err != nil {
		return fmt.Errorf("charge: %w", err)
	}
	return nil
}
```

## Testing with DI

```go
func TestUserService_CreateUser(t *testing.T) {
	t.Run("hashes password before saving", func(t *testing.T) {
		users := &fakeUserRepository{}
		hasher := &fakeHasher{hashed: "hashed_secret"}
		logger := &fakeLogger{}
		service := NewUserService(users, hasher, logger)

		_, err := service.CreateUser(context.Background(), CreateUserParams{
			Email:    "test@example.com",
			Password: "secret",
		})

		require.NoError(t, err)
		assert.Equal(t, "secret", hasher.gotPassword)
		assert.Equal(t, "hashed_secret", users.saved.Password)
	})

	t.Run("logs user creation", func(t *testing.T) {
		logger := &fakeLogger{}
		service := NewUserService(&fakeUserRepository{}, &fakeHasher{hashed: "hashed"}, logger)

		_, err := service.CreateUser(context.Background(), CreateUserParams{
			Email:    "test@example.com",
			Password: "secret",
		})

		require.NoError(t, err)
		assert.Contains(t, logger.messages, "Creating user")
	})
}

// Fakes implement the small consumer-side interfaces.
type fakeUserRepository struct {
	saved CreateUserParams
}

func (f *fakeUserRepository) Save(ctx context.Context, dto CreateUserParams) (*User, error) {
	f.saved = dto
	return &User{ID: "1", Email: dto.Email}, nil
}

type fakeHasher struct {
	gotPassword string
	hashed      string
}

func (f *fakeHasher) Hash(password string) (string, error) {
	f.gotPassword = password
	return f.hashed, nil
}

type fakeLogger struct {
	messages []string
}

func (f *fakeLogger) Log(message string) { f.messages = append(f.messages, message) }
```

## Best Practices

### 1. Depend on Abstractions

```go
// ❌ Depending on a concrete type
type OrderService struct {
	repo *PostgresOrderRepository
}

// ✅ Depending on a small interface
type OrderService struct {
	repo OrderRepository
}
```

### 2. Constructor Injection for Required Dependencies

```go
// ✅ Required dependencies are constructor parameters — impossible to forget.
type UserService struct {
	repository UserRepository // Required
	logger     Logger         // Required
}

func NewUserService(repository UserRepository, logger Logger) *UserService {
	return &UserService{repository: repository, logger: logger}
}
```

### 3. Optional Dependencies with Defaults

```go
// ✅ Optional dependencies via functional options with sensible defaults.
type CacheService struct {
	store CacheStore
	ttl   time.Duration
}

type CacheOption func(*CacheService)

func WithTTL(ttl time.Duration) CacheOption {
	return func(s *CacheService) { s.ttl = ttl }
}

func NewCacheService(store CacheStore, opts ...CacheOption) *CacheService {
	s := &CacheService{store: store, ttl: time.Hour}
	for _, opt := range opts {
		opt(s)
	}
	return s
}
```

### 4. Avoid Service Locator Anti-Pattern

```go
// ❌ Service locator — hides dependencies inside the method.
type OrderService struct{}

func (s *OrderService) Process(ctx context.Context, order Order) error {
	repository := serviceLocator.Get("OrderRepository").(OrderRepository)
	logger := serviceLocator.Get("Logger").(Logger)
	// ...
	_, _ = repository, logger
	return nil
}

// ✅ Explicit dependencies — visible in the struct and constructor.
type OrderService struct {
	repository OrderRepository
	logger     Logger
}

func NewOrderService(repository OrderRepository, logger Logger) *OrderService {
	return &OrderService{repository: repository, logger: logger}
}

func (s *OrderService) Process(ctx context.Context, order Order) error {
	// Dependencies are explicit and testable.
	return nil
}
```

## Summary

| Benefit | Description |
|---------|-------------|
| Testability | Easy to substitute fakes for dependencies |
| Flexibility | Swap implementations without code changes |
| Maintainability | Clear dependency graph |
| Reusability | Components work with any implementation |
| Separation | Structs focus on their responsibility |
