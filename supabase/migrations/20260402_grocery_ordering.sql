-- Grocery Ordering Infrastructure
-- Supports browser-agent based cart building and order placement

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE grocery_provider AS ENUM (
  'walmart',
  'amazon_fresh',
  'target',
  'instacart',
  'kroger'
);

CREATE TYPE grocery_order_status AS ENUM (
  'pending',
  'session_started',
  'building_cart',
  'cart_ready',
  'selecting_slot',
  'awaiting_review',
  'user_approved',
  'checkout_started',
  'completed',
  'failed',
  'cancelled'
);

CREATE TYPE cart_item_status AS ENUM (
  'found',
  'substituted',
  'not_found'
);

-- ============================================================================
-- USER PROVIDER ACCOUNTS
-- ============================================================================

CREATE TABLE user_provider_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  provider grocery_provider NOT NULL,
  
  -- Account info (email may be different from user's Ounje email)
  provider_email TEXT,
  provider_email_inbox_id TEXT,  -- Lumbox inbox ID for verification emails
  
  -- Session persistence (encrypted cookies)
  session_cookies TEXT,  -- JSON array of cookies
  
  -- Browser profile for session persistence
  browser_profile_id TEXT,
  
  -- Status
  is_active BOOLEAN DEFAULT true,
  last_used_at TIMESTAMPTZ,
  login_status TEXT DEFAULT 'unknown',  -- 'logged_in', 'needs_login', 'needs_verification'
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE(user_id, provider)
);

CREATE INDEX idx_user_provider_accounts_user ON user_provider_accounts(user_id);
CREATE INDEX idx_user_provider_accounts_provider ON user_provider_accounts(provider);

-- ============================================================================
-- GROCERY ORDERS
-- ============================================================================

CREATE TABLE grocery_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  meal_plan_id UUID,  -- Optional link to meal plan
  
  -- Provider info
  provider grocery_provider NOT NULL,
  provider_account_id UUID REFERENCES user_provider_accounts(id),
  
  -- Browser session
  browser_session_id TEXT,
  browser_live_url TEXT,  -- Live preview URL for debugging
  
  -- State machine
  status grocery_order_status NOT NULL DEFAULT 'pending',
  status_message TEXT,
  
  -- Request data
  requested_items JSONB NOT NULL,  -- Original GroceryItem[] from Ounje
  delivery_address JSONB NOT NULL,
  
  -- Cart result
  matched_items JSONB,  -- Items successfully added
  missing_items JSONB,  -- Items that couldn't be found
  substitutions JSONB,  -- Items that were substituted
  
  -- Pricing
  subtotal_cents INTEGER,
  delivery_fee_cents INTEGER,
  service_fee_cents INTEGER,
  tax_cents INTEGER,
  tip_cents INTEGER DEFAULT 0,
  total_cents INTEGER,
  
  -- Delivery
  delivery_slot JSONB,  -- { date, timeRange, fee }
  available_slots JSONB,
  
  -- Provider order
  provider_order_id TEXT,
  provider_cart_url TEXT,
  provider_checkout_url TEXT,
  
  -- Artifacts for debugging
  screenshots JSONB DEFAULT '[]',
  step_log JSONB DEFAULT '[]',
  
  -- Error handling
  error_code TEXT,
  error_message TEXT,
  retry_count INTEGER DEFAULT 0,
  
  -- Timestamps
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  cart_ready_at TIMESTAMPTZ,
  user_approved_at TIMESTAMPTZ,
  submitted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ
);

CREATE INDEX idx_grocery_orders_user ON grocery_orders(user_id);
CREATE INDEX idx_grocery_orders_status ON grocery_orders(status);
CREATE INDEX idx_grocery_orders_provider ON grocery_orders(provider);
CREATE INDEX idx_grocery_orders_created ON grocery_orders(created_at DESC);

-- ============================================================================
-- ORDER ITEMS (Denormalized for querying)
-- ============================================================================

CREATE TABLE grocery_order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES grocery_orders(id) ON DELETE CASCADE NOT NULL,
  
  -- Original request
  requested_name TEXT NOT NULL,
  requested_amount NUMERIC,
  requested_unit TEXT,
  
  -- Match result
  status cart_item_status NOT NULL,
  matched_name TEXT,
  matched_product_id TEXT,
  matched_brand TEXT,
  
  -- Pricing
  unit_price_cents INTEGER,
  quantity INTEGER DEFAULT 1,
  total_price_cents INTEGER,
  
  -- Metadata
  image_url TEXT,
  match_confidence NUMERIC,
  
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX idx_grocery_order_items_order ON grocery_order_items(order_id);

-- ============================================================================
-- USER VERIFICATION INBOXES
-- ============================================================================

CREATE TABLE user_verification_inboxes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  
  -- Lumbox inbox
  lumbox_inbox_id TEXT NOT NULL,
  email_address TEXT NOT NULL,  -- e.g., u_abc123@ounje.lumbox.co
  
  -- Status
  is_active BOOLEAN DEFAULT true,
  email_count INTEGER DEFAULT 0,
  last_email_at TIMESTAMPTZ,
  
  created_at TIMESTAMPTZ DEFAULT now(),
  
  UNIQUE(user_id)
);

CREATE INDEX idx_user_verification_inboxes_email ON user_verification_inboxes(email_address);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Update updated_at on grocery_orders
CREATE OR REPLACE FUNCTION update_grocery_order_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER grocery_orders_updated_at
  BEFORE UPDATE ON grocery_orders
  FOR EACH ROW
  EXECUTE FUNCTION update_grocery_order_timestamp();

-- Update updated_at on user_provider_accounts
CREATE TRIGGER user_provider_accounts_updated_at
  BEFORE UPDATE ON user_provider_accounts
  FOR EACH ROW
  EXECUTE FUNCTION update_grocery_order_timestamp();

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

ALTER TABLE user_provider_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE grocery_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE grocery_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_verification_inboxes ENABLE ROW LEVEL SECURITY;

-- Users can only see their own data
CREATE POLICY "Users can view own provider accounts"
  ON user_provider_accounts FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can manage own provider accounts"
  ON user_provider_accounts FOR ALL
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view own orders"
  ON grocery_orders FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can create own orders"
  ON grocery_orders FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own orders"
  ON grocery_orders FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can view own order items"
  ON grocery_order_items FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM grocery_orders
      WHERE grocery_orders.id = grocery_order_items.order_id
      AND grocery_orders.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can view own verification inboxes"
  ON user_verification_inboxes FOR SELECT
  USING (auth.uid() = user_id);

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE grocery_orders IS 'Browser-agent grocery ordering jobs';
COMMENT ON TABLE user_provider_accounts IS 'User accounts on grocery providers (Walmart, Amazon, etc.)';
COMMENT ON TABLE user_verification_inboxes IS 'Lumbox email inboxes for account verification';
COMMENT ON COLUMN grocery_orders.browser_session_id IS 'browser-use session ID for live control';
COMMENT ON COLUMN grocery_orders.browser_live_url IS 'URL to watch the browser agent work in real-time';
