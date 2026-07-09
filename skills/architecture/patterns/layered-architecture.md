---
name: layered-architecture
description: Traditional N-tier layered architecture pattern
category: architecture/patterns
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Layered Architecture (N-Tier)

## Overview

Layered Architecture organizes code into horizontal layers, where each
layer has a specific role and only depends on the layer directly below it.

## Traditional 3-Tier Architecture

```
┌─────────────────────────────────────┐
│       Presentation Layer            │  ← HTTP handlers / API
│   (User Interface / API Layer)      │
├─────────────────────────────────────┤
│          │                          │
│          ▼                          │
├─────────────────────────────────────┤
│        Business Layer               │  ← Business Logic, Services
│     (Business Logic Layer)          │
├─────────────────────────────────────┤
│          │                          │
│          ▼                          │
├─────────────────────────────────────┤
│         Data Layer                  │  ← Data Access, SQL
│     (Data Access Layer)             │
└─────────────────────────────────────┘
              │
              ▼
        ┌───────────┐
        │ Database  │
        └───────────┘
```

## 4-Tier Architecture (with Domain)

```
┌─────────────────────────────────────┐
│       Presentation Layer            │
├─────────────────────────────────────┤
│        Application Layer            │  ← Use Cases, Orchestration
├─────────────────────────────────────┤
│          Domain Layer               │  ← Business Rules, Entities
├─────────────────────────────────────┤
│      Infrastructure Layer           │  ← Data Access, External APIs
└─────────────────────────────────────┘
```

## Directory Structure

```
├── cmd/
│   └── app/
│       └── main.go                # composition root
│
└── internal/
    ├── presentation/          # Layer 1: HTTP handlers (chi)
    │   ├── user_handler.go
    │   └── order_handler.go
    │
    ├── business/              # Layer 2: services + business rules
    │   ├── user_service.go
    │   └── order_service.go
    │
    ├── data/                  # Layer 3: repositories + persistence models
    │   ├── user.go            # User model
    │   ├── user_repo.go
    │   ├── order.go           # Order model
    │   └── order_repo.go
    │
    └── middleware/            # Cross-cutting: logging, recover, auth
        ├── logging.go
        ├── recover.go
        └── auth.go
```

## Implementation

### Presentation Layer

```go
// internal/presentation/user_handler.go
package presentation

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/example/app/internal/business"
	"github.com/example/app/internal/data"
	"github.com/go-chi/chi/v5"
)

// userService is the business-layer port this handler consumes. It is declared
// here (the consumer) and kept small — the handler never sees the data layer.
type userService interface {
	Create(ctx context.Context, in business.CreateUserInput) (*data.User, error)
	FindByID(ctx context.Context, id string) (*data.User, error)
	FindAll(ctx context.Context) ([]*data.User, error)
}

// UserHandler is a presentation-layer adapter over the user service.
type UserHandler struct {
	users userService
}

// NewUserHandler wires the handler with its service.
func NewUserHandler(users userService) *UserHandler {
	return &UserHandler{users: users}
}

// Routes mounts the user endpoints. Auth checks live in middleware applied at
// the router (see the cross-cutting section).
func (h *UserHandler) Routes(r chi.Router) {
	r.Post("/users", h.Create)
	r.Get("/users/{id}", h.Get)
	r.Get("/users", h.List)
}

type createUserRequest struct {
	Email    string `json:"email"`
	Name     string `json:"name"`
	Password string `json:"password"`
}

// validate performs boundary validation with guard clauses. For richer rules,
// use github.com/go-playground/validator via struct tags.
func (req createUserRequest) validate() error {
	switch {
	case !strings.Contains(req.Email, "@"):
		return errors.New("email must be valid")
	case len(req.Name) < 2:
		return errors.New("name must be at least 2 characters")
	case len(req.Password) < 8:
		return errors.New("password must be at least 8 characters")
	default:
		return nil
	}
}

type userResponse struct {
	ID        string `json:"id"`
	Email     string `json:"email"`
	Name      string `json:"name"`
	CreatedAt string `json:"created_at"`
}

func toResponse(u *data.User) userResponse {
	return userResponse{
		ID:        u.ID,
		Email:     u.Email,
		Name:      u.Name,
		CreatedAt: u.CreatedAt.Format(time.RFC3339),
	}
}

// Create validates the request and delegates to the business layer.
func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if err := req.validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	u, err := h.users.Create(r.Context(), business.CreateUserInput{
		Email:    req.Email,
		Name:     req.Name,
		Password: req.Password,
	})
	switch {
	case errors.Is(err, business.ErrEmailExists):
		http.Error(w, err.Error(), http.StatusConflict)
		return
	case err != nil:
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusCreated, toResponse(u))
}

// Get returns one user by id.
func (h *UserHandler) Get(w http.ResponseWriter, r *http.Request) {
	u, err := h.users.FindByID(r.Context(), chi.URLParam(r, "id"))
	switch {
	case errors.Is(err, business.ErrUserNotFound):
		http.Error(w, "user not found", http.StatusNotFound)
		return
	case err != nil:
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, toResponse(u))
}

// List returns all users.
func (h *UserHandler) List(w http.ResponseWriter, r *http.Request) {
	users, err := h.users.FindAll(r.Context())
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	out := make([]userResponse, 0, len(users))
	for _, u := range users {
		out = append(out, toResponse(u))
	}
	writeJSON(w, http.StatusOK, out)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
```

### Business Layer

```go
// internal/business/user_service.go
package business

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/example/app/internal/data"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"
)

// Business errors surfaced to the presentation layer.
var (
	ErrEmailExists  = errors.New("email already exists")
	ErrUserNotFound = errors.New("user not found")
	ErrSamePassword = errors.New("new password must be different")
)

// UserRepository is the data-layer port the service consumes — declared here in
// the consumer (business layer), kept small.
type UserRepository interface {
	Save(ctx context.Context, u *data.User) error
	FindByID(ctx context.Context, id string) (*data.User, error)
	FindByEmail(ctx context.Context, email string) (*data.User, error)
	FindAll(ctx context.Context) ([]*data.User, error)
}

// UserService holds user business rules; it depends on the repository interface.
type UserService struct {
	users UserRepository
}

// NewUserService wires the service with its repository.
func NewUserService(users UserRepository) *UserService {
	return &UserService{users: users}
}

// CreateUserInput is the validated input to Create.
type CreateUserInput struct {
	Email    string
	Name     string
	Password string
}

// Create enforces email uniqueness, hashes the password, and persists the user.
func (s *UserService) Create(ctx context.Context, in CreateUserInput) (*data.User, error) {
	existing, err := s.users.FindByEmail(ctx, in.Email)
	if err != nil {
		return nil, fmt.Errorf("check email: %w", err)
	}
	if existing != nil {
		return nil, ErrEmailExists
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(in.Password), bcrypt.DefaultCost)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}

	u := &data.User{
		ID:           uuid.NewString(),
		Email:        in.Email,
		Name:         in.Name,
		PasswordHash: string(hash),
		CreatedAt:    time.Now(),
	}
	if err := s.users.Save(ctx, u); err != nil {
		return nil, fmt.Errorf("save user: %w", err)
	}
	return u, nil
}

// FindByID returns a user or ErrUserNotFound.
func (s *UserService) FindByID(ctx context.Context, id string) (*data.User, error) {
	u, err := s.users.FindByID(ctx, id)
	if err != nil {
		return nil, fmt.Errorf("find user: %w", err)
	}
	if u == nil {
		return nil, ErrUserNotFound
	}
	return u, nil
}

// FindAll lists all users.
func (s *UserService) FindAll(ctx context.Context) ([]*data.User, error) {
	users, err := s.users.FindAll(ctx)
	if err != nil {
		return nil, fmt.Errorf("list users: %w", err)
	}
	return users, nil
}

// UpdatePassword enforces the "must differ" rule and stores a new hash.
func (s *UserService) UpdatePassword(ctx context.Context, userID, newPassword string) error {
	u, err := s.users.FindByID(ctx, userID)
	if err != nil {
		return fmt.Errorf("find user: %w", err)
	}
	if u == nil {
		return ErrUserNotFound
	}

	// Business rule: the new password must differ from the current one.
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(newPassword)) == nil {
		return ErrSamePassword
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return fmt.Errorf("hash password: %w", err)
	}
	u.PasswordHash = string(hash)
	if err := s.users.Save(ctx, u); err != nil {
		return fmt.Errorf("save user: %w", err)
	}
	return nil
}
```

```go
// internal/business/order_service.go
package business

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/example/app/internal/data"
	"github.com/google/uuid"
)

// Order-related business errors.
var (
	ErrProductNotFound   = errors.New("product not found")
	ErrInsufficientStock = errors.New("insufficient stock")
)

// OrderRepository persists orders.
type OrderRepository interface {
	Save(ctx context.Context, o *data.Order) error
}

// ProductRepository loads products.
type ProductRepository interface {
	FindByID(ctx context.Context, id string) (*data.Product, error)
}

// userFinder is the slice of UserService this service needs — a service may call
// another service, but through a narrow interface, not the concrete type.
type userFinder interface {
	FindByID(ctx context.Context, id string) (*data.User, error)
}

// OrderService holds order business rules.
type OrderService struct {
	orders   OrderRepository
	products ProductRepository
	users    userFinder
}

// NewOrderService wires the service with its dependencies.
func NewOrderService(orders OrderRepository, products ProductRepository, users userFinder) *OrderService {
	return &OrderService{orders: orders, products: products, users: users}
}

// OrderItemInput is one requested line item.
type OrderItemInput struct {
	ProductID string
	Quantity  int64
}

// CreateOrder verifies the user, validates stock and totals, then persists.
func (s *OrderService) CreateOrder(ctx context.Context, userID string, items []OrderItemInput) (*data.Order, error) {
	// Verify the user exists (delegates to the user service).
	if _, err := s.users.FindByID(ctx, userID); err != nil {
		return nil, fmt.Errorf("verify user: %w", err)
	}

	// Calculate the total and validate stock.
	var total int64
	for _, item := range items {
		p, err := s.products.FindByID(ctx, item.ProductID)
		if err != nil {
			return nil, fmt.Errorf("load product %s: %w", item.ProductID, err)
		}
		if p == nil {
			return nil, fmt.Errorf("%s: %w", item.ProductID, ErrProductNotFound)
		}
		if p.Stock < item.Quantity {
			return nil, fmt.Errorf("%s: %w", p.Name, ErrInsufficientStock)
		}
		total += p.Price * item.Quantity
	}

	o := &data.Order{
		ID:        uuid.NewString(),
		UserID:    userID,
		Total:     total,
		Status:    "pending",
		CreatedAt: time.Now(),
	}
	if err := s.orders.Save(ctx, o); err != nil {
		return nil, fmt.Errorf("save order: %w", err)
	}
	return o, nil
}
```

### Data Layer

```go
// internal/data/user.go
package data

import "time"

// User is the persistence model for the users table.
type User struct {
	ID           string
	Email        string
	Name         string
	PasswordHash string
	CreatedAt    time.Time
	UpdatedAt    time.Time
}
```

```go
// internal/data/user_repo.go
package data

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// UserRepo is a pgx-backed repository over the users table. It returns a
// concrete struct; the business layer depends on its own small interface.
type UserRepo struct {
	pool *pgxpool.Pool
}

// NewUserRepo builds a repository over a pool.
func NewUserRepo(pool *pgxpool.Pool) *UserRepo {
	return &UserRepo{pool: pool}
}

// Save upserts a user with parameterized queries — never string concatenation.
func (r *UserRepo) Save(ctx context.Context, u *User) error {
	const q = `
		INSERT INTO users (id, email, name, password_hash, created_at)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO UPDATE SET
			email = EXCLUDED.email,
			name = EXCLUDED.name,
			password_hash = EXCLUDED.password_hash,
			updated_at = NOW()`
	if _, err := r.pool.Exec(ctx, q, u.ID, u.Email, u.Name, u.PasswordHash, u.CreatedAt); err != nil {
		return fmt.Errorf("save user %s: %w", u.ID, err)
	}
	return nil
}

// FindByID loads a user, or (nil, nil) when absent.
func (r *UserRepo) FindByID(ctx context.Context, id string) (*User, error) {
	const q = `SELECT id, email, name, password_hash, created_at FROM users WHERE id = $1`
	return r.queryOne(ctx, q, id)
}

// FindByEmail loads a user by email, or (nil, nil) when absent.
func (r *UserRepo) FindByEmail(ctx context.Context, email string) (*User, error) {
	const q = `SELECT id, email, name, password_hash, created_at FROM users WHERE email = $1`
	return r.queryOne(ctx, q, email)
}

// FindAll lists users, newest first.
func (r *UserRepo) FindAll(ctx context.Context) ([]*User, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, email, name, password_hash, created_at FROM users ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("query users: %w", err)
	}
	defer rows.Close()

	var users []*User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Email, &u.Name, &u.PasswordHash, &u.CreatedAt); err != nil {
			return nil, fmt.Errorf("scan user: %w", err)
		}
		users = append(users, &u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate users: %w", err)
	}
	return users, nil
}

// Delete removes a user by id.
func (r *UserRepo) Delete(ctx context.Context, id string) error {
	if _, err := r.pool.Exec(ctx, `DELETE FROM users WHERE id = $1`, id); err != nil {
		return fmt.Errorf("delete user %s: %w", id, err)
	}
	return nil
}

func (r *UserRepo) queryOne(ctx context.Context, query, arg string) (*User, error) {
	var u User
	err := r.pool.QueryRow(ctx, query, arg).
		Scan(&u.ID, &u.Email, &u.Name, &u.PasswordHash, &u.CreatedAt)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		return nil, nil
	case err != nil:
		return nil, fmt.Errorf("query user: %w", err)
	}
	return &u, nil
}
```

## Layer Dependencies

```
✅ Allowed Dependencies:
Presentation → Business → Data

❌ Forbidden Dependencies:
Data → Business (data layer shouldn't know business rules)
Business → Presentation (service shouldn't know about HTTP)
Data → Presentation (repository shouldn't format responses)
```

## Strict vs Relaxed Layering

### Strict Layering
Each layer can only access the layer immediately below.

```go
// ❌ Presentation reaching straight into the data layer
type UserHandler struct {
	users *data.UserRepo // WRONG: skips the business layer
}

// ✅ Presentation goes through the business layer
type UserHandler struct {
	users userService // an interface satisfied by *business.UserService
}
```

### Relaxed Layering
Layers can access any layer below them.

```go
// Presentation may read directly from the data layer for reporting queries
type ReportHandler struct {
	orders  orderService    // business layer (writes, rules)
	reports *data.ReportRepo // data layer (read-only reporting)
}
```

## Cross-Cutting Concerns

```
┌─────────────────────────────────────┐
│       Presentation Layer            │
├──────────────────────┬──────────────┤
│                      │              │
│    Business Layer    │  Logging     │
│                      │  Security    │
├──────────────────────┤  Caching     │
│                      │  Error       │
│      Data Layer      │  Handling    │
│                      │              │
└──────────────────────┴──────────────┘
```

### Implementation

Cross-cutting concerns are `net/http` middleware — composable `func(http.Handler)
http.Handler` wrappers, applied once at the router.

```go
// internal/middleware/logging.go
package middleware

import (
	"log/slog"
	"net/http"
	"time"
)

// Logging emits one structured line per request: method, path, status, latency.
func Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

		next.ServeHTTP(rec, r)

		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration", time.Since(start),
		)
	})
}

// statusRecorder captures the status code written by downstream handlers.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}
```

```go
// internal/middleware/recover.go
package middleware

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// Recover turns a panic into a 500 JSON response instead of crashing the
// process — the layered analogue of a global exception filter.
func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			rec := recover()
			if rec == nil {
				return
			}
			slog.Error("panic recovered", "err", rec, "path", r.URL.Path)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status_code": http.StatusInternalServerError,
				"message":     "internal server error",
				"timestamp":   time.Now().Format(time.RFC3339),
			})
		}()
		next.ServeHTTP(w, r)
	})
}
```

## Advantages and Disadvantages

### Advantages

| Advantage | Description |
|-----------|-------------|
| Simplicity | Easy to understand and implement |
| Separation | Clear separation of concerns |
| Testability | Layers can be tested independently |
| Familiar | Well-known pattern, easy onboarding |

### Disadvantages

| Disadvantage | Description |
|--------------|-------------|
| Coupling | Changes can cascade through layers |
| Overhead | May require passing data through layers |
| Rigidity | Strict rules can feel constraining |
| Database-Centric | Often becomes data-driven design |

## When to Use

### Good Fit
- CRUD-heavy applications
- Small to medium projects
- Teams familiar with traditional patterns
- Applications with clear layer boundaries

### Consider Alternatives When
- Complex domain logic (use DDD)
- Multiple delivery mechanisms (use Hexagonal)
- Microservices (use Clean Architecture)
- Event-driven systems (use CQRS)

## Migration Path

```
Layered Architecture
        ↓
Add interfaces at layer boundaries
        ↓
Introduce domain layer
        ↓
Clean Architecture / Hexagonal
```
