---
name: repository-pattern
description: Repository pattern for data access abstraction
category: architecture/design-patterns/structural
applies_to: go
allowed-tools: Read, Write, Glob, Grep, Bash
user-invocable: false
context: inject
---

# Repository Pattern

## Overview

The Repository pattern mediates between the domain and data mapping layers,
acting like an in-memory collection of domain objects. It provides a clean
separation between data access logic and business logic.

## Basic Repository Interface

```go
package user

import (
	"context"
	"time"
)

type UserRole string

const (
	RoleAdmin  UserRole = "admin"
	RoleMember UserRole = "member"
)

// User is a domain object; db tags let a driver map columns to fields.
type User struct {
	ID        string    `db:"id"`
	Email     string    `db:"email"`
	Name      string    `db:"name"`
	Role      UserRole  `db:"role"`
	IsActive  bool      `db:"is_active"`
	CreatedAt time.Time `db:"created_at"`
	UpdatedAt time.Time `db:"updated_at"`
}

type OrderStatus string

type Order struct {
	ID         string
	CustomerID string
	Status     OrderStatus
	CreatedAt  time.Time
}

// Repository is a generic CRUD interface over an aggregate root.
// A nil *T with a nil error means "not found".
type Repository[T any, ID comparable] interface {
	FindByID(ctx context.Context, id ID) (*T, error)
	FindAll(ctx context.Context) ([]T, error)
	Save(ctx context.Context, entity T) (T, error)
	Delete(ctx context.Context, id ID) error
	Exists(ctx context.Context, id ID) (bool, error)
}

// UserRepository is the domain-specific interface the consumer declares.
type UserRepository interface {
	Repository[User, string]
	FindByEmail(ctx context.Context, email string) (*User, error)
	FindByRole(ctx context.Context, role UserRole) ([]User, error)
	FindActive(ctx context.Context) ([]User, error)
}

type OrderRepository interface {
	Repository[Order, string]
	FindByCustomerID(ctx context.Context, customerID string) ([]Order, error)
	FindByStatus(ctx context.Context, status OrderStatus) ([]Order, error)
	FindByDateRange(ctx context.Context, start, end time.Time) ([]Order, error)
}
```

## Implementation

### In-Memory Repository (Testing)

```go
package user

import (
	"context"
	"sync"
)

type InMemoryUserRepository struct {
	mu    sync.RWMutex
	users map[string]User
}

func NewInMemoryUserRepository() *InMemoryUserRepository {
	return &InMemoryUserRepository{users: make(map[string]User)}
}

func (r *InMemoryUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	user, ok := r.users[id]
	if !ok {
		return nil, nil
	}
	return &user, nil
}

func (r *InMemoryUserRepository) FindAll(ctx context.Context) ([]User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]User, 0, len(r.users))
	for _, u := range r.users {
		out = append(out, u)
	}
	return out, nil
}

func (r *InMemoryUserRepository) Save(ctx context.Context, user User) (User, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.users[user.ID] = user
	return user, nil
}

func (r *InMemoryUserRepository) Delete(ctx context.Context, id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.users, id)
	return nil
}

func (r *InMemoryUserRepository) Exists(ctx context.Context, id string) (bool, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, ok := r.users[id]
	return ok, nil
}

func (r *InMemoryUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, u := range r.users {
		if u.Email == email {
			found := u
			return &found, nil
		}
	}
	return nil, nil
}

func (r *InMemoryUserRepository) FindByRole(ctx context.Context, role UserRole) ([]User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []User
	for _, u := range r.users {
		if u.Role == role {
			out = append(out, u)
		}
	}
	return out, nil
}

func (r *InMemoryUserRepository) FindActive(ctx context.Context) ([]User, error) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []User
	for _, u := range r.users {
		if u.IsActive {
			out = append(out, u)
		}
	}
	return out, nil
}

// Test helpers.
func (r *InMemoryUserRepository) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	clear(r.users)
}

func (r *InMemoryUserRepository) Seed(users ...User) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, u := range users {
		r.users[u.ID] = u
	}
}
```

### SQL Repository

```go
package user

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

const userColumns = `id, email, name, role, is_active, created_at, updated_at`

type SQLUserRepository struct {
	db *sql.DB
}

func NewSQLUserRepository(db *sql.DB) *SQLUserRepository {
	return &SQLUserRepository{db: db}
}

// scanner is satisfied by both *sql.Row and *sql.Rows.
type scanner interface {
	Scan(dest ...any) error
}

func (r *SQLUserRepository) scanUser(s scanner) (User, error) {
	var u User
	if err := s.Scan(&u.ID, &u.Email, &u.Name, &u.Role, &u.IsActive, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return User{}, err
	}
	return u, nil
}

func (r *SQLUserRepository) queryUsers(ctx context.Context, query string, args ...any) ([]User, error) {
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query users: %w", err)
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		u, err := r.scanUser(rows)
		if err != nil {
			return nil, fmt.Errorf("scan user: %w", err)
		}
		users = append(users, u)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate users: %w", err)
	}
	return users, nil
}

func (r *SQLUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	user, err := r.scanUser(r.db.QueryRowContext(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find user by id: %w", err)
	}
	return &user, nil
}

func (r *SQLUserRepository) FindAll(ctx context.Context) ([]User, error) {
	return r.queryUsers(ctx, `SELECT `+userColumns+` FROM users ORDER BY created_at DESC`)
}

func (r *SQLUserRepository) Save(ctx context.Context, user User) (User, error) {
	const query = `
		INSERT INTO users (id, email, name, role, is_active, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO UPDATE SET
			email = $2, name = $3, role = $4, is_active = $5, updated_at = $7`
	user.UpdatedAt = time.Now()
	if _, err := r.db.ExecContext(ctx, query,
		user.ID, user.Email, user.Name, user.Role, user.IsActive, user.CreatedAt, user.UpdatedAt,
	); err != nil {
		return User{}, fmt.Errorf("save user: %w", err)
	}
	return user, nil
}

func (r *SQLUserRepository) Delete(ctx context.Context, id string) error {
	if _, err := r.db.ExecContext(ctx, `DELETE FROM users WHERE id = $1`, id); err != nil {
		return fmt.Errorf("delete user: %w", err)
	}
	return nil
}

func (r *SQLUserRepository) Exists(ctx context.Context, id string) (bool, error) {
	var exists bool
	if err := r.db.QueryRowContext(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)`, id).Scan(&exists); err != nil {
		return false, fmt.Errorf("check user exists: %w", err)
	}
	return exists, nil
}

func (r *SQLUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	user, err := r.scanUser(r.db.QueryRowContext(ctx, `SELECT `+userColumns+` FROM users WHERE email = $1`, email))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("find user by email: %w", err)
	}
	return &user, nil
}

func (r *SQLUserRepository) FindByRole(ctx context.Context, role UserRole) ([]User, error) {
	return r.queryUsers(ctx, `SELECT `+userColumns+` FROM users WHERE role = $1`, role)
}

func (r *SQLUserRepository) FindActive(ctx context.Context) ([]User, error) {
	return r.queryUsers(ctx, `SELECT `+userColumns+` FROM users WHERE is_active = true`)
}
```

### pgx Repository

```go
package user

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// pgxQuerier is the subset of pgx used here.
// Both *pgxpool.Pool and pgx.Tx satisfy it, so the same repository works
// standalone or inside a transaction — pgx replaces an ORM's row mapping.
type pgxQuerier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

type PgxUserRepository struct {
	db pgxQuerier
}

func NewPgxUserRepository(db pgxQuerier) *PgxUserRepository {
	return &PgxUserRepository{db: db}
}

func (r *PgxUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	rows, err := r.db.Query(ctx, `SELECT `+userColumns+` FROM users WHERE id = $1`, id)
	if err != nil {
		return nil, fmt.Errorf("query user by id: %w", err)
	}
	user, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[User])
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("collect user: %w", err)
	}
	return &user, nil
}

func (r *PgxUserRepository) FindAll(ctx context.Context) ([]User, error) {
	rows, err := r.db.Query(ctx, `SELECT `+userColumns+` FROM users ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("query users: %w", err)
	}
	users, err := pgx.CollectRows(rows, pgx.RowToStructByName[User])
	if err != nil {
		return nil, fmt.Errorf("collect users: %w", err)
	}
	return users, nil
}

func (r *PgxUserRepository) Save(ctx context.Context, user User) (User, error) {
	const query = `
		INSERT INTO users (id, email, name, role, is_active, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (id) DO UPDATE SET
			email = $2, name = $3, role = $4, is_active = $5, updated_at = $7`
	user.UpdatedAt = time.Now()
	if _, err := r.db.Exec(ctx, query,
		user.ID, user.Email, user.Name, user.Role, user.IsActive, user.CreatedAt, user.UpdatedAt,
	); err != nil {
		return User{}, fmt.Errorf("save user: %w", err)
	}
	return user, nil
}

func (r *PgxUserRepository) Delete(ctx context.Context, id string) error {
	if _, err := r.db.Exec(ctx, `DELETE FROM users WHERE id = $1`, id); err != nil {
		return fmt.Errorf("delete user: %w", err)
	}
	return nil
}

func (r *PgxUserRepository) Exists(ctx context.Context, id string) (bool, error) {
	var exists bool
	if err := r.db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)`, id).Scan(&exists); err != nil {
		return false, fmt.Errorf("check user exists: %w", err)
	}
	return exists, nil
}

func (r *PgxUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	rows, err := r.db.Query(ctx, `SELECT `+userColumns+` FROM users WHERE email = $1`, email)
	if err != nil {
		return nil, fmt.Errorf("query user by email: %w", err)
	}
	user, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[User])
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("collect user: %w", err)
	}
	return &user, nil
}

func (r *PgxUserRepository) FindByRole(ctx context.Context, role UserRole) ([]User, error) {
	rows, err := r.db.Query(ctx, `SELECT `+userColumns+` FROM users WHERE role = $1`, role)
	if err != nil {
		return nil, fmt.Errorf("query users by role: %w", err)
	}
	users, err := pgx.CollectRows(rows, pgx.RowToStructByName[User])
	if err != nil {
		return nil, fmt.Errorf("collect users: %w", err)
	}
	return users, nil
}

func (r *PgxUserRepository) FindActive(ctx context.Context) ([]User, error) {
	rows, err := r.db.Query(ctx, `SELECT `+userColumns+` FROM users WHERE is_active = true`)
	if err != nil {
		return nil, fmt.Errorf("query active users: %w", err)
	}
	users, err := pgx.CollectRows(rows, pgx.RowToStructByName[User])
	if err != nil {
		return nil, fmt.Errorf("collect users: %w", err)
	}
	return users, nil
}
```

## Specification Pattern

```go
package user

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Specification is satisfied in memory and can render its SQL predicate.
// argPos points at the next positional placeholder ($1, $2, ...) so
// composed specifications number their parameters consistently.
type Specification[T any] interface {
	IsSatisfiedBy(entity T) bool
	ToSQL(argPos *int) (string, []any)
}

type UserIsActiveSpec struct{}

func (UserIsActiveSpec) IsSatisfiedBy(u User) bool { return u.IsActive }

func (UserIsActiveSpec) ToSQL(argPos *int) (string, []any) {
	return "is_active = true", nil
}

type UserHasRoleSpec struct {
	Role UserRole
}

func (s UserHasRoleSpec) IsSatisfiedBy(u User) bool { return u.Role == s.Role }

func (s UserHasRoleSpec) ToSQL(argPos *int) (string, []any) {
	clause := fmt.Sprintf("role = $%d", *argPos)
	*argPos++
	return clause, []any{s.Role}
}

type UserCreatedAfterSpec struct {
	After time.Time
}

func (s UserCreatedAfterSpec) IsSatisfiedBy(u User) bool { return u.CreatedAt.After(s.After) }

func (s UserCreatedAfterSpec) ToSQL(argPos *int) (string, []any) {
	clause := fmt.Sprintf("created_at > $%d", *argPos)
	*argPos++
	return clause, []any{s.After}
}

// AndSpecification composes specifications. The predicate text comes only
// from trusted specification code; every value stays a bound parameter.
type AndSpecification[T any] struct {
	Specs []Specification[T]
}

func (a AndSpecification[T]) IsSatisfiedBy(entity T) bool {
	for _, spec := range a.Specs {
		if !spec.IsSatisfiedBy(entity) {
			return false
		}
	}
	return true
}

func (a AndSpecification[T]) ToSQL(argPos *int) (string, []any) {
	clauses := make([]string, 0, len(a.Specs))
	var params []any
	for _, spec := range a.Specs {
		clause, p := spec.ToSQL(argPos)
		clauses = append(clauses, "("+clause+")")
		params = append(params, p...)
	}
	return strings.Join(clauses, " AND "), params
}

// Repository with specification support.
type SpecificationRepository[T any, ID comparable] interface {
	Repository[T, ID]
	FindBySpec(ctx context.Context, spec Specification[T]) ([]T, error)
	CountBySpec(ctx context.Context, spec Specification[T]) (int, error)
}

func (r *SQLUserRepository) FindBySpec(ctx context.Context, spec Specification[User]) ([]User, error) {
	argPos := 1
	clause, params := spec.ToSQL(&argPos)
	return r.queryUsers(ctx, `SELECT `+userColumns+` FROM users WHERE `+clause, params...)
}

func (r *SQLUserRepository) CountBySpec(ctx context.Context, spec Specification[User]) (int, error) {
	argPos := 1
	clause, params := spec.ToSQL(&argPos)
	var count int
	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE `+clause, params...).Scan(&count); err != nil {
		return 0, fmt.Errorf("count by spec: %w", err)
	}
	return count, nil
}

// Usage
func activeAdmins(ctx context.Context, repo *SQLUserRepository) ([]User, error) {
	return repo.FindBySpec(ctx, AndSpecification[User]{
		Specs: []Specification[User]{
			UserIsActiveSpec{},
			UserHasRoleSpec{Role: RoleAdmin},
			UserCreatedAfterSpec{After: time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)},
		},
	})
}
```

## Unit of Work Pattern

```go
package user

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// UnitOfWork groups repositories that share a single transaction.
type UnitOfWork struct {
	tx     pgx.Tx
	users  UserRepository
	orders OrderRepository
}

// BeginUnitOfWork opens a transaction and binds repositories to it.
func BeginUnitOfWork(ctx context.Context, pool *pgxpool.Pool) (*UnitOfWork, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin transaction: %w", err)
	}
	return &UnitOfWork{
		tx:     tx,
		users:  NewPgxUserRepository(tx),
		orders: NewPgxOrderRepository(tx),
	}, nil
}

func (u *UnitOfWork) Users() UserRepository   { return u.users }
func (u *UnitOfWork) Orders() OrderRepository { return u.orders }

func (u *UnitOfWork) Commit(ctx context.Context) error {
	if err := u.tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}
	return nil
}

func (u *UnitOfWork) Rollback(ctx context.Context) error {
	if err := u.tx.Rollback(ctx); err != nil {
		return fmt.Errorf("rollback transaction: %w", err)
	}
	return nil
}

// Usage
func TransferOrder(ctx context.Context, pool *pgxpool.Pool, userID, orderID string) (err error) {
	uow, err := BeginUnitOfWork(ctx, pool)
	if err != nil {
		return fmt.Errorf("begin unit of work: %w", err)
	}
	// Roll back unless we commit; Rollback after Commit is a harmless no-op.
	defer func() {
		if rbErr := uow.Rollback(ctx); rbErr != nil && !errors.Is(rbErr, pgx.ErrTxClosed) && err == nil {
			err = rbErr
		}
	}()

	user, err := uow.Users().FindByID(ctx, userID)
	if err != nil {
		return fmt.Errorf("find user: %w", err)
	}
	order, err := uow.Orders().FindByID(ctx, orderID)
	if err != nil {
		return fmt.Errorf("find order: %w", err)
	}
	if user == nil || order == nil {
		return errors.New("user or order not found")
	}

	order.AssignTo(user)

	if _, err := uow.Orders().Save(ctx, *order); err != nil {
		return fmt.Errorf("save order: %w", err)
	}
	return uow.Commit(ctx)
}
```

## Caching Repository Decorator

```go
package user

import (
	"context"
	"fmt"
	"time"
)

// Cache is the small interface the decorator needs.
type Cache interface {
	Get(ctx context.Context, key string) (*User, bool, error)
	Set(ctx context.Context, key string, user *User, ttl time.Duration) error
	Delete(ctx context.Context, keys ...string) error
}

// CachedUserRepository decorates a UserRepository with a read-through cache.
type CachedUserRepository struct {
	next  UserRepository
	cache Cache
	ttl   time.Duration
}

func NewCachedUserRepository(next UserRepository, cache Cache, ttl time.Duration) *CachedUserRepository {
	return &CachedUserRepository{next: next, cache: cache, ttl: ttl}
}

func (r *CachedUserRepository) FindByID(ctx context.Context, id string) (*User, error) {
	key := "user:" + id
	cached, ok, err := r.cache.Get(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("cache get: %w", err)
	}
	if ok {
		return cached, nil
	}

	user, err := r.next.FindByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if user != nil {
		if err := r.cache.Set(ctx, key, user, r.ttl); err != nil {
			return nil, fmt.Errorf("cache set: %w", err)
		}
	}
	return user, nil
}

func (r *CachedUserRepository) Save(ctx context.Context, user User) (User, error) {
	saved, err := r.next.Save(ctx, user)
	if err != nil {
		return User{}, err
	}
	if err := r.cache.Delete(ctx, "user:"+user.ID, "user:email:"+user.Email); err != nil {
		return User{}, fmt.Errorf("cache invalidate: %w", err)
	}
	return saved, nil
}

func (r *CachedUserRepository) FindByEmail(ctx context.Context, email string) (*User, error) {
	key := "user:email:" + email
	cached, ok, err := r.cache.Get(ctx, key)
	if err != nil {
		return nil, fmt.Errorf("cache get: %w", err)
	}
	if ok {
		return cached, nil
	}

	user, err := r.next.FindByEmail(ctx, email)
	if err != nil {
		return nil, err
	}
	if user != nil {
		if err := r.cache.Set(ctx, key, user, r.ttl); err != nil {
			return nil, fmt.Errorf("cache set: %w", err)
		}
	}
	return user, nil
}

// Remaining methods delegate straight to the wrapped repository:
//
//	func (r *CachedUserRepository) FindAll(ctx context.Context) ([]User, error) {
//		return r.next.FindAll(ctx)
//	}
//	// ... Delete, Exists, FindByRole, FindActive ...
```

## Benefits

| Benefit | Description |
|---------|-------------|
| Testability | Easy to mock for unit tests |
| Separation | Data access isolated from business logic |
| Flexibility | Swap storage implementations |
| Domain Focus | Domain objects stay pure |
| Query Reuse | Common queries defined once |

## When to Use

- Complex domain models
- Multiple data sources
- Need for unit testing
- ORM abstraction needed
- CQRS/Clean Architecture
