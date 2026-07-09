---
name: solid-principles
description: SOLID principles for object-oriented design
category: architecture/principles
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# SOLID Principles

## Overview

SOLID is an acronym for five design principles that make software
more understandable, flexible, and maintainable. In Go they map onto
small interfaces, composition over inheritance, and constructor
injection rather than classes and frameworks.

## S - Single Responsibility Principle

> A type should have only one reason to change.

### Bad Example
```go
// ❌ Type has multiple responsibilities
type User struct {
	Name  string
	Email string
}

// User data management
func (u *User) Save(ctx context.Context) error {
	// Save to database
	return nil
}

// Email functionality
func (u *User) SendWelcomeEmail(ctx context.Context) error {
	// Send email
	return nil
}

// Report generation
func (u *User) GenerateReport() string {
	// Generate user report
	return ""
}
```

### Good Example
```go
// ✅ Each type has a single responsibility
type User struct {
	ID    string
	Name  string
	Email string
}

type UserRepository struct {
	db *pgxpool.Pool
}

func NewUserRepository(db *pgxpool.Pool) *UserRepository {
	return &UserRepository{db: db}
}

func (r *UserRepository) Save(ctx context.Context, user *User) error {
	// Database operations only
	return nil
}

func (r *UserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	// Query operations
	return nil, nil
}

// EmailSender is the small abstraction the email service depends on.
type EmailSender interface {
	Send(ctx context.Context, to, subject, body string) error
}

type UserEmailService struct {
	sender EmailSender
}

func NewUserEmailService(sender EmailSender) *UserEmailService {
	return &UserEmailService{sender: sender}
}

func (s *UserEmailService) SendWelcomeEmail(ctx context.Context, user *User) error {
	// Email operations only
	return s.sender.Send(ctx, user.Email, "Welcome!", "…")
}

type UserReportGenerator struct{}

func NewUserReportGenerator() *UserReportGenerator {
	return &UserReportGenerator{}
}

func (g *UserReportGenerator) Generate(user *User) string {
	// Report generation only
	return ""
}
```

## O - Open/Closed Principle

> Software entities should be open for extension but closed for modification.

### Bad Example
```go
// ❌ Must modify this function to add new payment types
type PaymentProcessor struct{}

func (p *PaymentProcessor) Process(ctx context.Context, kind string, amount int64) error {
	switch kind {
	case "credit_card":
		// Process credit card
	case "paypal":
		// Process PayPal
	case "stripe":
		// Process Stripe — had to modify the switch!
	}
	return nil
}
```

### Good Example
```go
// ✅ Open for extension via new implementations

type PaymentResult struct {
	TransactionID string
}

// PaymentMethod is a small interface declared in the consumer package.
type PaymentMethod interface {
	Process(ctx context.Context, amount int64) (PaymentResult, error)
}

type CreditCardPayment struct{}

func (CreditCardPayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	// Credit card logic
	return PaymentResult{}, nil
}

type PayPalPayment struct{}

func (PayPalPayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	// PayPal logic
	return PaymentResult{}, nil
}

// Adding a new payment type doesn't touch existing code.
type StripePayment struct{}

func (StripePayment) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	// Stripe logic
	return PaymentResult{}, nil
}

type PaymentProcessor struct {
	method PaymentMethod
}

func NewPaymentProcessor(method PaymentMethod) *PaymentProcessor {
	return &PaymentProcessor{method: method}
}

func (p *PaymentProcessor) Process(ctx context.Context, amount int64) (PaymentResult, error) {
	return p.method.Process(ctx, amount)
}
```

## L - Liskov Substitution Principle

> A value satisfying an interface must be usable anywhere that interface is
> expected, without breaking the caller's expectations.

### Bad Example
```go
// ❌ Square violates LSP — code written against Shape's mutators breaks
type Shape interface {
	SetWidth(w int)
	SetHeight(h int)
	Area() int
}

type Rectangle struct {
	width, height int
}

func (r *Rectangle) SetWidth(w int)  { r.width = w }
func (r *Rectangle) SetHeight(h int) { r.height = h }
func (r *Rectangle) Area() int       { return r.width * r.height }

type Square struct {
	side int
}

func (s *Square) SetWidth(w int)  { s.side = w } // silently also sets height
func (s *Square) SetHeight(h int) { s.side = h } // clobbers the width
func (s *Square) Area() int       { return s.side * s.side }

// Written against Shape, this misbehaves for Square
func resize(s Shape) {
	s.SetWidth(10)
	s.SetHeight(5)
	fmt.Println(s.Area()) // Rectangle: 50, Square: 25
}
```

### Good Example
```go
// ✅ Model the real abstraction — a Shape only needs an area
type Shape interface {
	Area() int
}

type Rectangle struct {
	width, height int
}

func NewRectangle(width, height int) Rectangle {
	return Rectangle{width: width, height: height}
}

func (r Rectangle) Area() int { return r.width * r.height }

type Square struct {
	side int
}

func NewSquare(side int) Square {
	return Square{side: side}
}

func (s Square) Area() int { return s.side * s.side }
```

## I - Interface Segregation Principle

> Clients should not be forced to depend on methods they don't use.

### Bad Example
```go
// ❌ Fat interface forces meaningless implementations
type Worker interface {
	Work()
	Eat()
	Sleep()
	AttendMeeting()
	WriteCode()
}

type Robot struct{}

func (Robot) Work()          { /* OK */ }
func (Robot) Eat()           { panic("robots don't eat") }   // Forced!
func (Robot) Sleep()         { panic("robots don't sleep") } // Forced!
func (Robot) AttendMeeting() { /* OK */ }
func (Robot) WriteCode()     { /* OK */ }
```

### Good Example
```go
// ✅ Segregated, single-purpose interfaces
type Worker interface {
	Work()
}

type Eater interface {
	Eat()
}

type Sleeper interface {
	Sleep()
}

type Coder interface {
	WriteCode()
}

// A human satisfies all of them.
type Human struct{}

func (Human) Work()      { /* ... */ }
func (Human) Eat()       { /* ... */ }
func (Human) Sleep()     { /* ... */ }
func (Human) WriteCode() { /* ... */ }

// A robot implements only what it actually does — no Eat or Sleep.
type Robot struct{}

func (Robot) Work()      { /* ... */ }
func (Robot) WriteCode() { /* ... */ }
```

## D - Dependency Inversion Principle

> High-level modules should not depend on low-level modules.
> Both should depend on abstractions.

### Bad Example
```go
// ❌ High-level type depends on a concrete low-level type
type MySQLDatabase struct{}

func (MySQLDatabase) Save(ctx context.Context, data any) error {
	// MySQL specific
	return nil
}

type UserService struct {
	db MySQLDatabase // Tight coupling!
}

func (s *UserService) CreateUser(ctx context.Context, data UserData) error {
	return s.db.Save(ctx, data)
}
```

### Good Example
```go
// ✅ Both depend on an abstraction owned by the consumer
type Store interface {
	Save(ctx context.Context, data any) error
	Find(ctx context.Context, query any) (any, error)
}

type MySQLDatabase struct{}

func (MySQLDatabase) Save(ctx context.Context, data any) error         { return nil }
func (MySQLDatabase) Find(ctx context.Context, query any) (any, error) { return nil, nil }

type PostgresDatabase struct{}

func (PostgresDatabase) Save(ctx context.Context, data any) error         { return nil }
func (PostgresDatabase) Find(ctx context.Context, query any) (any, error) { return nil, nil }

type UserService struct {
	store Store // injected
}

func NewUserService(store Store) *UserService {
	return &UserService{store: store}
}

func (s *UserService) CreateUser(ctx context.Context, data UserData) error {
	return s.store.Save(ctx, data)
}

// Easy to switch implementations at composition time.
func main() {
	svc := NewUserService(PostgresDatabase{})
	_ = svc
}
```

## Summary Table

| Principle | Focus | Benefit |
|-----------|-------|---------|
| SRP | One responsibility per type | Easier maintenance |
| OCP | Extend without modifying | Reduced regression risk |
| LSP | Substitutable implementations | Reliable polymorphism |
| ISP | Focused interfaces | Cleaner dependencies |
| DIP | Depend on abstractions | Flexible, testable code |

## Application Guidelines

### When to Apply
- New type/package design
- Refactoring legacy code
- Code review checklist
- Architecture decisions

### Common Violations
- God types (SRP)
- Type switches on a `kind` string (OCP)
- Panicking in a stubbed method (LSP, ISP)
- Direct construction of dependencies inside a type (DIP)

### Testing Benefits
- SRP: Focused unit tests
- OCP: Test extensions independently
- LSP: Polymorphic test cases work
- ISP: Fake only the methods you need
- DIP: Easy dependency substitution
