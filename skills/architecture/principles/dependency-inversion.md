---
name: dependency-inversion
description: Decoupling high-level and low-level modules through abstractions
category: architecture/principles
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Dependency Inversion Principle (DIP)

## Overview

The Dependency Inversion Principle states:
1. High-level modules should not depend on low-level modules. Both should depend on abstractions.
2. Abstractions should not depend on details. Details should depend on abstractions.

In Go this falls out naturally: the consumer declares a small interface, and
low-level packages provide concrete structs that satisfy it. Wiring happens
in a single composition root.

## The Problem

```
Traditional Dependency Flow (Problematic):
┌──────────────────┐
│   Controller     │ ─────────────────────────┐
└────────┬─────────┘                          │
         │ depends on                         │
         ▼                                    │
┌──────────────────┐                          │ All dependencies
│    Service       │ ─────────────────────────┤ flow downward
└────────┬─────────┘                          │
         │ depends on                         │
         ▼                                    │
┌──────────────────┐                          │
│   Repository     │ ─────────────────────────┤
└────────┬─────────┘                          │
         │ depends on                         │
         ▼                                    │
┌──────────────────┐                          │
│   MySQL Driver   │ ─────────────────────────┘
└──────────────────┘
```

## The Solution

```
Inverted Dependency Flow (DIP Applied):
┌──────────────────┐
│   Handler        │
└────────┬─────────┘
         │ depends on interface
         ▼
┌──────────────────┐
│   «interface»    │ ◄──────────┐
│   UserService    │            │
└────────┬─────────┘            │
         △                      │
         │ implements           │
┌────────┴─────────┐            │
│   userService    │────────────┤ High-level defines
└────────┬─────────┘            │ the interfaces
         │ depends on interface │
         ▼                      │
┌──────────────────┐            │
│   «interface»    │ ◄──────────┘
│  UserRepository  │
└────────┬─────────┘
         △
         │ implements
┌────────┴─────────┐
│ MySQLUserRepo    │  ← Low-level implements
└──────────────────┘
```

## Implementation Patterns

### Pattern 1: Constructor Injection

```go
// ❌ Without DIP — tightly coupled
type UserService struct {
	repo  *MySQLUserRepository  // direct dependency on a concrete type
	email *SendGridEmailService // direct dependency on a concrete type
}

func NewUserService() *UserService {
	return &UserService{
		repo:  NewMySQLUserRepository(),
		email: NewSendGridEmailService(),
	}
}

func (s *UserService) CreateUser(ctx context.Context, in CreateUserInput) (*User, error) {
	u, err := s.repo.Save(ctx, in)
	if err != nil {
		return nil, err
	}
	if err := s.email.SendWelcome(ctx, u.Email); err != nil {
		return nil, err
	}
	return u, nil
}

// ✅ With DIP — loosely coupled

// Abstractions declared in the consumer (service) package.
type UserRepository interface {
	Save(ctx context.Context, in CreateUserInput) (*User, error)
	FindByID(ctx context.Context, id string) (*User, error)
	FindByEmail(ctx context.Context, email string) (*User, error)
}

type EmailService interface {
	SendWelcome(ctx context.Context, email string) error
}

// The service depends on abstractions.
type UserService struct {
	repo  UserRepository
	email EmailService
}

func NewUserService(repo UserRepository, email EmailService) *UserService {
	return &UserService{repo: repo, email: email}
}

func (s *UserService) CreateUser(ctx context.Context, in CreateUserInput) (*User, error) {
	u, err := s.repo.Save(ctx, in)
	if err != nil {
		return nil, fmt.Errorf("save user: %w", err)
	}
	if err := s.email.SendWelcome(ctx, u.Email); err != nil {
		return nil, fmt.Errorf("send welcome email: %w", err)
	}
	return u, nil
}

// Infrastructure implements the abstractions with concrete structs.
type MySQLUserRepository struct {
	db *sql.DB
}

func NewMySQLUserRepository(db *sql.DB) *MySQLUserRepository {
	return &MySQLUserRepository{db: db}
}

func (r *MySQLUserRepository) Save(ctx context.Context, in CreateUserInput) (*User, error) {
	// MySQL implementation
	return &User{}, nil
}

func (r *MySQLUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	return nil, nil
}

func (r *MySQLUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	return nil, nil
}

type SendGridEmailService struct {
	apiKey string
}

func NewSendGridEmailService(apiKey string) *SendGridEmailService {
	return &SendGridEmailService{apiKey: apiKey}
}

func (s *SendGridEmailService) SendWelcome(ctx context.Context, email string) error {
	// SendGrid implementation
	return nil
}

// Composition at startup.
func main() {
	db := mustOpenDB()
	repo := NewMySQLUserRepository(db)
	email := NewSendGridEmailService(os.Getenv("SENDGRID_API_KEY"))
	userService := NewUserService(repo, email)
	_ = userService
}
```

### Pattern 2: Composition Root

```go
// Go favors an explicit composition root over a runtime DI container.
// All construction happens in one place; dependencies flow in as arguments,
// and interface variables document which abstraction each concrete satisfies.

// app/wire.go
type App struct {
	UserService *UserService
}

func NewApp(cfg Config) (*App, error) {
	db, err := sql.Open("mysql", cfg.DSN)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	var (
		repo  UserRepository = NewMySQLUserRepository(db)
		email EmailService   = NewSendGridEmailService(cfg.SendGridAPIKey)
	)

	return &App{
		UserService: NewUserService(repo, email),
	}, nil
}

// For larger graphs, google/wire generates this wiring at compile time:
//
//	//go:build wireinject
//	func InitApp(cfg Config) (*App, error) {
//		wire.Build(
//			NewMySQLUserRepository,
//			wire.Bind(new(UserRepository), new(*MySQLUserRepository)),
//			NewSendGridEmailService,
//			wire.Bind(new(EmailService), new(*SendGridEmailService)),
//			NewUserService,
//			wire.Struct(new(App), "*"),
//		)
//		return nil, nil
//	}
```

### Pattern 3: Factory Pattern with DIP

```go
// When you need a runtime decision between implementations.

type PaymentType string

const (
	PaymentStripe PaymentType = "stripe"
	PaymentPayPal PaymentType = "paypal"
)

type ChargeResult struct{ ID string }
type RefundResult struct{ ID string }

type PaymentGateway interface {
	Charge(ctx context.Context, amount int64) (ChargeResult, error)
	Refund(ctx context.Context, chargeID string) (RefundResult, error)
}

// GatewayFactory is the abstraction the service depends on.
type GatewayFactory interface {
	For(kind PaymentType) (PaymentGateway, error)
}

type DefaultGatewayFactory struct {
	stripe PaymentGateway
	paypal PaymentGateway
}

func NewDefaultGatewayFactory(stripe, paypal PaymentGateway) *DefaultGatewayFactory {
	return &DefaultGatewayFactory{stripe: stripe, paypal: paypal}
}

func (f *DefaultGatewayFactory) For(kind PaymentType) (PaymentGateway, error) {
	switch kind {
	case PaymentStripe:
		return f.stripe, nil
	case PaymentPayPal:
		return f.paypal, nil
	default:
		return nil, fmt.Errorf("unknown payment type: %q", kind)
	}
}

// The service uses the factory abstraction.
type PaymentService struct {
	factory GatewayFactory
}

func NewPaymentService(factory GatewayFactory) *PaymentService {
	return &PaymentService{factory: factory}
}

func (s *PaymentService) ProcessPayment(ctx context.Context, order Order, kind PaymentType) (*Payment, error) {
	gateway, err := s.factory.For(kind)
	if err != nil {
		return nil, fmt.Errorf("select gateway: %w", err)
	}
	result, err := gateway.Charge(ctx, order.Total)
	if err != nil {
		return nil, fmt.Errorf("charge order %s: %w", order.ID, err)
	}
	return NewPayment(order.ID, result), nil
}
```

## Layer Organization with DIP

```
internal/
├── domain/                      # Core business logic (no external deps)
│   ├── user.go                  # User entity
│   ├── repository.go            # UserRepository interface (consumer-owned)
│   ├── email.go                 # EmailService interface
│   └── errors.go
│
├── app/                         # Use cases (depend on domain interfaces)
│   ├── create_user.go           # Uses the UserRepository interface
│   └── input.go
│
├── infra/                       # Implementations (depend on domain interfaces)
│   ├── mysql/
│   │   └── user_repository.go   # implements domain.UserRepository
│   ├── postgres/
│   │   └── user_repository.go
│   ├── email/
│   │   ├── sendgrid.go          # implements domain.EmailService
│   │   └── ses.go
│   └── wire/
│       └── app.go               # Wire everything together
│
└── transport/                   # HTTP/gRPC/CLI (depends on app)
    └── http/
        └── handlers.go
```

## Dependency Direction Rules

```go
// ✅ CORRECT: the consumer defines the interface, infrastructure implements it

// internal/user/user.go (HIGH-LEVEL — consumer package)
package user

type Repository interface {
	Save(ctx context.Context, u *User) error
	FindByID(ctx context.Context, id string) (*User, error)
}

// internal/infra/mysql/user_repository.go (LOW-LEVEL)
package mysql

// Implements user.Repository — the low-level package depends on the high-level one.
type UserRepository struct {
	db *sql.DB
}

func (r *UserRepository) Save(ctx context.Context, u *user.User) error { return nil }
func (r *UserRepository) FindByID(ctx context.Context, id string) (*user.User, error) {
	return nil, nil
}


// ❌ WRONG: infrastructure defines the interface the domain must depend on

// internal/infra/mysql/mysql.go (LOW-LEVEL defining the abstraction)
package mysql

type Client[T any] interface { // infrastructure-specific leak
	Query(ctx context.Context, sql string) ([]T, error)
	Exec(ctx context.Context, sql string) error
}

// internal/user/service.go (HIGH-LEVEL now importing infrastructure)
package user

import "example.com/app/internal/infra/mysql" // wrong direction!

type Service struct {
	client mysql.Client[User] // coupled to MySQL!
}
```

## Testing Benefits

```go
// Easy to test with fakes that implement the interfaces.
type stubUserRepository struct {
	saved   *User
	saveErr error
}

func (s *stubUserRepository) Save(ctx context.Context, in CreateUserInput) (*User, error) {
	if s.saveErr != nil {
		return nil, s.saveErr
	}
	s.saved = &User{ID: "1", Email: in.Email}
	return s.saved, nil
}

func (s *stubUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	return nil, nil
}

func (s *stubUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	return nil, nil
}

type spyEmailService struct {
	called     bool
	calledWith string
}

func (s *spyEmailService) SendWelcome(ctx context.Context, email string) error {
	s.called = true
	s.calledWith = email
	return nil
}

func TestUserService_CreateUser(t *testing.T) {
	t.Run("creates user and sends welcome email", func(t *testing.T) {
		repo := &stubUserRepository{}
		email := &spyEmailService{}
		svc := NewUserService(repo, email)

		got, err := svc.CreateUser(context.Background(), CreateUserInput{Email: "test@example.com"})

		require.NoError(t, err)
		assert.Equal(t, "test@example.com", got.Email)
		assert.True(t, email.called)
		assert.Equal(t, "test@example.com", email.calledWith)
	})

	t.Run("does not send email when save fails", func(t *testing.T) {
		repo := &stubUserRepository{saveErr: errors.New("db error")}
		email := &spyEmailService{}
		svc := NewUserService(repo, email)

		_, err := svc.CreateUser(context.Background(), CreateUserInput{Email: "test@example.com"})

		require.Error(t, err)
		assert.False(t, email.called)
	})
}
```

## Common Violations

### 1. Concrete Type Dependencies

```go
// ❌ Depending on a concrete type
type OrderService struct {
	stripe *stripe.Client // concrete!
}

func NewOrderService() *OrderService {
	return &OrderService{stripe: stripe.New(os.Getenv("STRIPE_KEY"))}
}

// ✅ Depending on an abstraction
type OrderService struct {
	gateway PaymentGateway
}

func NewOrderService(gateway PaymentGateway) *OrderService {
	return &OrderService{gateway: gateway}
}
```

### 2. Framework Dependencies in Domain

```go
// ❌ Domain coupled to the persistence framework
import "gorm.io/gorm"

type User struct {
	gorm.Model        // framework type embedded in the domain entity!
	Email      string `gorm:"uniqueIndex"`
}

// ✅ Pure domain entity — no tags, no framework
type User struct {
	ID    string
	Email string
	Name  string
}

func NewUser(id, email, name string) *User {
	return &User{ID: id, Email: email, Name: name}
}

// The persistence model lives in the infrastructure layer.
type userRow struct {
	ID        string `gorm:"primaryKey"`
	Email     string `gorm:"uniqueIndex"`
	Name      string
	CreatedAt time.Time
}
```

### 3. Hard-Wired Package-Level Calls

```go
// ❌ A fixed package-level call is hard to substitute in tests
type UserService struct{}

func (s *UserService) HashPassword(password string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// ✅ Inject the capability behind a small interface
type PasswordHasher interface {
	Hash(password string) (string, error)
	Verify(password, hash string) error
}

type BcryptHasher struct {
	cost int
}

func NewBcryptHasher(cost int) *BcryptHasher {
	return &BcryptHasher{cost: cost}
}

func (h *BcryptHasher) Hash(password string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(password), h.cost)
	if err != nil {
		return "", fmt.Errorf("hash password: %w", err)
	}
	return string(b), nil
}

func (h *BcryptHasher) Verify(password, hash string) error {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
}
```

## Summary

| Aspect | Without DIP | With DIP |
|--------|-------------|----------|
| Coupling | High-level → Low-level | Both → Abstractions |
| Testing | Hard (real dependencies) | Easy (fake interfaces) |
| Flexibility | Hard to change implementations | Swap implementations easily |
| Compile-time | Changes cascade | Isolated changes |
| Dependencies | Point downward | Point toward domain |
