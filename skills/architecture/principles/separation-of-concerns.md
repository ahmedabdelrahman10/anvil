---
name: separation-of-concerns
description: Organizing code by distinct responsibilities
category: architecture/principles
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Separation of Concerns (SoC)

## Overview

Separation of Concerns is the principle of dividing a program into
distinct sections, each addressing a separate concern. A concern is
a set of information that affects the code.

## Core Concept

```
┌─────────────────────────────────────────────────────────────┐
│                      Application                             │
├─────────────────┬─────────────────┬─────────────────────────┤
│   Presentation  │    Business     │     Data Access          │
│   (HTTP/gRPC)   │    Logic        │     (Persistence)        │
├─────────────────┼─────────────────┼─────────────────────────┤
│ • Handlers      │ • Services      │ • Repositories           │
│ • Middleware    │ • Domain Models │ • Database Clients       │
│ • DTOs          │ • Validators    │ • Query Builders         │
│ • Encoders      │ • Business Rules│ • Cache                  │
└─────────────────┴─────────────────┴─────────────────────────┘
```

## Bad Example - Mixed Concerns

```go
// ❌ Handler doing everything
func (h *UserHandler) CreateUser(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}

	// Validation (should be separate)
	if body.Email == "" || !strings.Contains(body.Email, "@") {
		http.Error(w, "invalid email", http.StatusBadRequest)
		return
	}
	if len(body.Password) < 8 {
		http.Error(w, "password too short", http.StatusBadRequest)
		return
	}

	// Business logic (should be in a service)
	hashed, err := bcrypt.GenerateFromPassword([]byte(body.Password), bcrypt.DefaultCost)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Direct database access (should be in a repository)
	var exists bool
	if err := h.db.QueryRow(ctx,
		"SELECT EXISTS(SELECT 1 FROM users WHERE email = $1)", body.Email,
	).Scan(&exists); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	if exists {
		http.Error(w, "email already exists", http.StatusConflict)
		return
	}

	var (
		id        string
		createdAt time.Time
	)
	if err := h.db.QueryRow(ctx,
		"INSERT INTO users (email, password, created_at) VALUES ($1, $2, NOW()) RETURNING id, created_at",
		body.Email, string(hashed),
	).Scan(&id, &createdAt); err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	// Email sending (should be a separate service)
	_ = h.mailer.Send(ctx, body.Email, "Welcome!", "<h1>Welcome</h1>")

	// Logging mixed in (should be middleware)
	log.Printf("user created: %s", id)

	// Response formatting mixed with logic
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"id":        id,
		"email":     body.Email,
		"createdAt": createdAt.Format(time.RFC3339),
	})
}
```

## Good Example - Separated Concerns

```go
// ✅ Presentation layer — HTTP handler
// user/transport/http.go
type UserHandler struct {
	users *user.Service
}

func NewUserHandler(users *user.Service) *UserHandler {
	return &UserHandler{users: users}
}

func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req CreateUserRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if err := req.Validate(); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	u, err := h.users.Create(r.Context(), req.toInput())
	if err != nil {
		writeError(w, err) // centralized domain-error → HTTP mapping
		return
	}

	writeJSON(w, http.StatusCreated, toUserResponse(u))
}

// ✅ Presentation layer — request DTO + validation
// user/transport/dto.go
type CreateUserRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

func (r CreateUserRequest) Validate() error {
	if r.Email == "" || !strings.Contains(r.Email, "@") {
		return errors.New("invalid email")
	}
	if len(r.Password) < 8 {
		return errors.New("password must be at least 8 characters")
	}
	return nil
}

// ✅ Presentation layer — response mapping
type UserResponse struct {
	ID        string `json:"id"`
	Email     string `json:"email"`
	CreatedAt string `json:"createdAt"`
}

func toUserResponse(u *user.User) UserResponse {
	return UserResponse{
		ID:        u.ID,
		Email:     u.Email,
		CreatedAt: u.CreatedAt.Format(time.RFC3339),
	}
}

// ✅ Business layer — service
// user/service.go
type Service struct {
	repo      Repository
	hasher    PasswordHasher
	publisher EventPublisher
}

func NewService(repo Repository, hasher PasswordHasher, publisher EventPublisher) *Service {
	return &Service{repo: repo, hasher: hasher, publisher: publisher}
}

func (s *Service) Create(ctx context.Context, in CreateUserInput) (*User, error) {
	exists, err := s.repo.ExistsByEmail(ctx, in.Email)
	if err != nil {
		return nil, fmt.Errorf("check email: %w", err)
	}
	if exists {
		return nil, fmt.Errorf("%w: %s", ErrEmailAlreadyExists, in.Email)
	}

	hashed, err := s.hasher.Hash(in.Password)
	if err != nil {
		return nil, fmt.Errorf("hash password: %w", err)
	}

	u := NewUser(in.Email, hashed)
	if err := s.repo.Save(ctx, u); err != nil {
		return nil, fmt.Errorf("save user: %w", err)
	}

	// Side effects via events
	if err := s.publisher.Publish(ctx, UserCreated{UserID: u.ID, Email: u.Email}); err != nil {
		return nil, fmt.Errorf("publish user created: %w", err)
	}
	return u, nil
}

// Repository is the small persistence port the service depends on
// (declared in the consumer package).
type Repository interface {
	Save(ctx context.Context, u *User) error
	ExistsByEmail(ctx context.Context, email string) (bool, error)
}

// ✅ Data access layer — repository implementation
// user/postgres/repository.go
type PostgresRepository struct {
	db *pgxpool.Pool
}

func NewPostgresRepository(db *pgxpool.Pool) *PostgresRepository {
	return &PostgresRepository{db: db}
}

func (r *PostgresRepository) Save(ctx context.Context, u *User) error {
	if _, err := r.db.Exec(ctx,
		"INSERT INTO users (id, email, password, created_at) VALUES ($1, $2, $3, $4)",
		u.ID, u.Email, u.Password, u.CreatedAt,
	); err != nil {
		return fmt.Errorf("insert user: %w", err)
	}
	return nil
}

func (r *PostgresRepository) ExistsByEmail(ctx context.Context, email string) (bool, error) {
	var exists bool
	if err := r.db.QueryRow(ctx,
		"SELECT EXISTS(SELECT 1 FROM users WHERE email = $1)", email,
	).Scan(&exists); err != nil {
		return false, fmt.Errorf("query user by email: %w", err)
	}
	return exists, nil
}

// ✅ Infrastructure — event handler (separate concern)
// user/events/welcome.go
type WelcomeEmailHandler struct {
	email EmailService
}

func NewWelcomeEmailHandler(email EmailService) *WelcomeEmailHandler {
	return &WelcomeEmailHandler{email: email}
}

func (h *WelcomeEmailHandler) Handle(ctx context.Context, event UserCreated) error {
	return h.email.SendWelcome(ctx, event.Email)
}
```

## Horizontal vs Vertical Separation

### Horizontal (Layer-based)

```
┌─────────────────────────────────────────┐
│           Presentation Layer            │  ← HTTP, gRPC, CLI
├─────────────────────────────────────────┤
│           Application Layer             │  ← Use Cases, Services
├─────────────────────────────────────────┤
│             Domain Layer                │  ← Business Logic
├─────────────────────────────────────────┤
│          Infrastructure Layer           │  ← DB, External APIs
└─────────────────────────────────────────┘
```

### Vertical (Feature-based)

```
┌─────────────┬─────────────┬─────────────┐
│    Users    │   Orders    │  Products   │
├─────────────┼─────────────┼─────────────┤
│ Handler     │ Handler     │ Handler     │
│ Service     │ Service     │ Service     │
│ Repository  │ Repository  │ Repository  │
│ Entity      │ Entity      │ Entity      │
└─────────────┴─────────────┴─────────────┘
```

### Combined Approach (Recommended)

```
internal/
├── user/                     # Vertical slice (one package per feature)
│   ├── user.go               # Domain entity + Repository interface
│   ├── service.go            # Application/business logic
│   ├── transport/            # Horizontal layer (HTTP/gRPC handlers, DTOs)
│   │   ├── http.go
│   │   └── dto.go
│   ├── postgres/             # Infrastructure (Repository implementation)
│   │   └── repository.go
│   └── events/               # Infrastructure (event handlers)
│       └── welcome.go
├── order/
└── product/
shared/                       # Cross-cutting concerns
├── middleware/
└── validation/
```

## Cross-Cutting Concerns

Some concerns span multiple layers and need special handling.

### Logging

```go
// ❌ Logging scattered through the service
func (s *OrderService) Create(ctx context.Context, in CreateOrderInput) (*Order, error) {
	log.Printf("creating order: %+v", in)
	order, err := s.doCreate(ctx, in)
	if err != nil {
		log.Printf("failed to create order: %v", err)
		return nil, err
	}
	log.Printf("order created: %s", order.ID)
	return order, nil
}

// ✅ Logging as a cross-cutting concern — HTTP middleware
func LoggingMiddleware(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

			next.ServeHTTP(rec, r)

			logger.InfoContext(r.Context(), "request",
				slog.String("method", r.Method),
				slog.String("path", r.URL.Path),
				slog.Int("status", rec.status),
				slog.Duration("took", time.Since(start)),
			)
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}
```

### Authentication/Authorization

```go
// ❌ Auth logic mixed into the handler
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	claims, err := verifyToken(r.Context(), token)
	if err != nil || !slices.Contains(claims.Permissions, "create:orders") {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	// Business logic starts here...
}

// ✅ Auth as a separate concern — middleware

type claimsKey struct{}

// TokenVerifier is the small port the auth middleware depends on.
type TokenVerifier func(ctx context.Context, token string) (Claims, error)

func Authenticate(verify TokenVerifier) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			claims, err := verify(r.Context(), token)
			if err != nil {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			ctx := context.WithValue(r.Context(), claimsKey{}, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func RequirePermission(perm string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := r.Context().Value(claimsKey{}).(Claims)
			if !ok || !slices.Contains(claims.Permissions, perm) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// Usage — a clean handler with the checks applied at the route:
//
//	r.With(Authenticate(verifier), RequirePermission("create:orders")).
//		Post("/orders", orderHandler.Create)
func (h *OrderHandler) Create(w http.ResponseWriter, r *http.Request) {
	// Pure business logic
	var req CreateOrderRequest
	// ... decode, call service ...
	_ = req
}
```

### Error Handling

```go
// ❌ Error handling mixed in everywhere
func (s *ProductService) FindByID(ctx context.Context, id string) (*Product, error) {
	product, err := s.repo.FindByID(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, &httpError{status: 404, message: "product not found"}
		}
		return nil, &httpError{status: 503, message: "database unavailable"}
	}
	return product, nil
}

// ✅ Centralized error handling
// Domain errors — no HTTP concepts leak into the domain
var ErrProductNotFound = errors.New("product not found")

// Service returns domain errors, wrapping the cause for context
func (s *ProductService) FindByID(ctx context.Context, id string) (*Product, error) {
	product, err := s.repo.FindByID(ctx, id)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%w: %s", ErrProductNotFound, id)
	}
	if err != nil {
		return nil, fmt.Errorf("find product %s: %w", id, err)
	}
	return product, nil
}

type errorBody struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// A single mapping from domain errors to HTTP responses
func writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrProductNotFound):
		writeJSON(w, http.StatusNotFound, errorBody{Error: "NOT_FOUND", Message: err.Error()})
	case errors.As(err, new(*ValidationError)):
		writeJSON(w, http.StatusBadRequest, errorBody{Error: "VALIDATION_ERROR", Message: err.Error()})
	default:
		writeJSON(w, http.StatusInternalServerError, errorBody{Error: "INTERNAL_ERROR", Message: "an unexpected error occurred"})
	}
}
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Maintainability | Changes in one area don't affect others |
| Testability | Units can be tested in isolation |
| Reusability | Components can be reused in different contexts |
| Understandability | Code is organized logically |
| Parallel Development | Teams can work on different concerns |

## Warning Signs of Mixed Concerns

- Handlers running database queries directly
- Services formatting HTTP responses or writing to `http.ResponseWriter`
- Domain structs carrying transport (`json`) or ORM tags
- Business logic living in middleware
- Database row structs returned directly as API responses
- Configuration values hardcoded in business logic
