-- =====================================================================
-- V1: initial schema (MySQL 8.4)
--
-- Conventions
--   * Tables: plural snake_case. Enums stored as VARCHAR + CHECK
--     (maps to @Enumerated(EnumType.STRING) in JPA).
--   * Money: DECIMAL(12,2). Quantities: DECIMAL(10,3) (0.5 = half a dozen).
--   * Cash-report dates (payment_date, expense_date) are plain DATE so
--     "which day does this money belong to" never depends on time zones.
--   * Tenant isolation: every main table carries business_id, and
--     composite foreign keys (id, business_id) make the database itself
--     reject a row that points to another business's data.
--   * created_at is set by the application (JPA auditing), no DB defaults.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Business (the SaaS account) and its users
-- ---------------------------------------------------------------------
CREATE TABLE businesses (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    name        VARCHAR(120) NOT NULL,
    created_at  DATETIME(6)  NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE users (
    id             BIGINT       NOT NULL AUTO_INCREMENT,
    business_id    BIGINT       NOT NULL,
    email          VARCHAR(255) NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,
    role           VARCHAR(20)  NOT NULL,
    enabled        BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     DATETIME(6)  NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_users_email UNIQUE (email),
    CONSTRAINT fk_users_business FOREIGN KEY (business_id) REFERENCES businesses (id),
    CONSTRAINT ck_users_role CHECK (role IN ('ADMIN', 'EMPLOYEE'))
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE INDEX idx_users_business ON users (business_id);

-- ---------------------------------------------------------------------
-- Ventures (empanadas, locro, ...) and customers
-- ---------------------------------------------------------------------
CREATE TABLE ventures (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    business_id  BIGINT       NOT NULL,
    name         VARCHAR(100) NOT NULL,
    active       BOOLEAN      NOT NULL DEFAULT TRUE,
    PRIMARY KEY (id),
    CONSTRAINT uk_ventures_business_name UNIQUE (business_id, name),
    -- target of composite FKs from other tables
    CONSTRAINT uk_ventures_id_business UNIQUE (id, business_id),
    CONSTRAINT fk_ventures_business FOREIGN KEY (business_id) REFERENCES businesses (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE customers (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    business_id  BIGINT       NOT NULL,
    name         VARCHAR(150) NOT NULL,
    phone        VARCHAR(40)  NULL,
    address      VARCHAR(255) NULL,
    notes        VARCHAR(500) NULL,
    active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   DATETIME(6)  NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_customers_id_business UNIQUE (id, business_id),
    CONSTRAINT fk_customers_business FOREIGN KEY (business_id) REFERENCES businesses (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE INDEX idx_customers_business_name ON customers (business_id, name);
CREATE INDEX idx_customers_business_phone ON customers (business_id, phone);

-- ---------------------------------------------------------------------
-- Catalog: products and their variants
-- (if a detail changes price or cost, it is a variant, not a column)
-- ---------------------------------------------------------------------
CREATE TABLE products (
    id           BIGINT       NOT NULL AUTO_INCREMENT,
    business_id  BIGINT       NOT NULL,
    venture_id   BIGINT       NOT NULL,
    name         VARCHAR(150) NOT NULL,
    description  VARCHAR(500) NULL,
    active       BOOLEAN      NOT NULL DEFAULT TRUE,
    PRIMARY KEY (id),
    CONSTRAINT fk_products_venture FOREIGN KEY (venture_id, business_id)
        REFERENCES ventures (id, business_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE INDEX idx_products_business_venture ON products (business_id, venture_id);

CREATE TABLE product_variants (
    id          BIGINT         NOT NULL AUTO_INCREMENT,
    product_id  BIGINT         NOT NULL,
    name        VARCHAR(100)   NOT NULL,
    unit        VARCHAR(30)    NOT NULL,
    price       DECIMAL(12, 2) NOT NULL,
    cost        DECIMAL(12, 2) NOT NULL DEFAULT 0,
    active      BOOLEAN        NOT NULL DEFAULT TRUE,
    PRIMARY KEY (id),
    CONSTRAINT uk_variants_product_name UNIQUE (product_id, name),
    CONSTRAINT fk_variants_product FOREIGN KEY (product_id) REFERENCES products (id),
    CONSTRAINT ck_variants_price CHECK (price >= 0),
    CONSTRAINT ck_variants_cost CHECK (cost >= 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- Orders and their items
-- unit_price / unit_cost are snapshots taken when the item is added,
-- so changing a variant's price later never rewrites history.
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    id                BIGINT         NOT NULL AUTO_INCREMENT,
    business_id       BIGINT         NOT NULL,
    venture_id        BIGINT         NOT NULL,
    customer_id       BIGINT         NOT NULL,
    status            VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    delivery_type     VARCHAR(10)    NOT NULL DEFAULT 'PICKUP',
    delivery_address  VARCHAR(255)   NULL,
    delivery_date     DATE           NOT NULL,
    total             DECIMAL(12, 2) NOT NULL DEFAULT 0,
    notes             VARCHAR(500)   NULL,
    created_at        DATETIME(6)    NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_orders_venture FOREIGN KEY (venture_id, business_id)
        REFERENCES ventures (id, business_id),
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id, business_id)
        REFERENCES customers (id, business_id),
    CONSTRAINT ck_orders_status CHECK (status IN
        ('PENDING', 'CONFIRMED', 'IN_PREPARATION', 'READY', 'DELIVERED', 'CANCELLED')),
    CONSTRAINT ck_orders_delivery_type CHECK (delivery_type IN ('PICKUP', 'DELIVERY')),
    CONSTRAINT ck_orders_total CHECK (total >= 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- "orders for today / next days" and per-venture views
CREATE INDEX idx_orders_business_venture_date ON orders (business_id, venture_id, delivery_date);
-- filter by status
CREATE INDEX idx_orders_business_status ON orders (business_id, status);

CREATE TABLE order_items (
    id          BIGINT         NOT NULL AUTO_INCREMENT,
    order_id    BIGINT         NOT NULL,
    variant_id  BIGINT         NOT NULL,
    quantity    DECIMAL(10, 3) NOT NULL,
    unit_price  DECIMAL(12, 2) NOT NULL,
    unit_cost   DECIMAL(12, 2) NOT NULL,
    subtotal    DECIMAL(12, 2) NOT NULL,
    detail      VARCHAR(255)   NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE,
    CONSTRAINT fk_items_variant FOREIGN KEY (variant_id) REFERENCES product_variants (id),
    CONSTRAINT ck_items_quantity CHECK (quantity > 0),
    CONSTRAINT ck_items_amounts CHECK (unit_price >= 0 AND unit_cost >= 0 AND subtotal >= 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE INDEX idx_items_order ON order_items (order_id);
CREATE INDEX idx_items_variant ON order_items (variant_id);

-- ---------------------------------------------------------------------
-- Payments (deposit, balance, full payment...). No ON DELETE CASCADE on
-- purpose: money records must never disappear silently.
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    id            BIGINT         NOT NULL AUTO_INCREMENT,
    order_id      BIGINT         NOT NULL,
    method        VARCHAR(20)    NOT NULL,
    amount        DECIMAL(12, 2) NOT NULL,
    payment_date  DATE           NOT NULL,
    created_at    DATETIME(6)    NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders (id),
    CONSTRAINT ck_payments_method CHECK (method IN ('CASH', 'BANK_TRANSFER', 'MERCADO_PAGO', 'OTHER')),
    CONSTRAINT ck_payments_amount CHECK (amount > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- cash reports: join by order, filter by date range
CREATE INDEX idx_payments_order_date ON payments (order_id, payment_date);
CREATE INDEX idx_payments_date ON payments (payment_date);

-- ---------------------------------------------------------------------
-- Expenses. venture_id is NULL for shared expenses (rent, gas used by
-- several ventures): they only affect the general cash.
-- ---------------------------------------------------------------------
CREATE TABLE expense_categories (
    id           BIGINT      NOT NULL AUTO_INCREMENT,
    business_id  BIGINT      NOT NULL,
    name         VARCHAR(80) NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_expense_categories_business_name UNIQUE (business_id, name),
    CONSTRAINT uk_expense_categories_id_business UNIQUE (id, business_id),
    CONSTRAINT fk_expense_categories_business FOREIGN KEY (business_id) REFERENCES businesses (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE TABLE expenses (
    id           BIGINT         NOT NULL AUTO_INCREMENT,
    business_id  BIGINT         NOT NULL,
    venture_id   BIGINT         NULL,
    category_id  BIGINT         NOT NULL,
    expense_date DATE           NOT NULL,
    amount       DECIMAL(12, 2) NOT NULL,
    method       VARCHAR(20)    NOT NULL,
    description  VARCHAR(255)   NULL,
    created_at   DATETIME(6)    NOT NULL,
    PRIMARY KEY (id),
    -- not enforced when venture_id is NULL (shared expense), as intended
    CONSTRAINT fk_expenses_venture FOREIGN KEY (venture_id, business_id)
        REFERENCES ventures (id, business_id),
    CONSTRAINT fk_expenses_category FOREIGN KEY (category_id, business_id)
        REFERENCES expense_categories (id, business_id),
    CONSTRAINT ck_expenses_method CHECK (method IN ('CASH', 'BANK_TRANSFER', 'MERCADO_PAGO', 'OTHER')),
    CONSTRAINT ck_expenses_amount CHECK (amount > 0)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

CREATE INDEX idx_expenses_business_date ON expenses (business_id, expense_date);
CREATE INDEX idx_expenses_venture_date ON expenses (venture_id, expense_date);