export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  api: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      my_organizations: {
        Row: {
          created_at: string | null
          current_period_end: string | null
          id: string | null
          logo_path: string | null
          member_count: number | null
          name: string | null
          plan_id: string | null
          role: Database["public"]["Enums"]["org_role"] | null
          slug: string | null
          subscription_status:
            | Database["public"]["Enums"]["subscription_status"]
            | null
          trial_ends_at: string | null
        }
        Relationships: [
          {
            foreignKeyName: "subscriptions_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
        ]
      }
      plans: {
        Row: {
          billing_interval: string | null
          currency: string | null
          description: string | null
          features: Json | null
          id: string | null
          limits: Json | null
          name: string | null
          price_cents: number | null
          sort_order: number | null
        }
        Insert: {
          billing_interval?: string | null
          currency?: string | null
          description?: string | null
          features?: Json | null
          id?: string | null
          limits?: Json | null
          name?: string | null
          price_cents?: number | null
          sort_order?: number | null
        }
        Update: {
          billing_interval?: string | null
          currency?: string | null
          description?: string | null
          features?: Json | null
          id?: string | null
          limits?: Json | null
          name?: string | null
          price_cents?: number | null
          sort_order?: number | null
        }
        Relationships: []
      }
    }
    Functions: {
      [_ in never]: never
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      allergens: {
        Row: {
          code: string
          created_at: string
          label: string
        }
        Insert: {
          code: string
          created_at?: string
          label: string
        }
        Update: {
          code?: string
          created_at?: string
          label?: string
        }
        Relationships: []
      }
      api_keys: {
        Row: {
          created_at: string
          created_by: string | null
          expires_at: string | null
          id: string
          key_hash: string
          last_used_at: string | null
          name: string
          organization_id: string
          prefix: string
          revoked_at: string | null
          scopes: string[]
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          key_hash: string
          last_used_at?: string | null
          name: string
          organization_id: string
          prefix: string
          revoked_at?: string | null
          scopes?: string[]
        }
        Update: {
          created_at?: string
          created_by?: string | null
          expires_at?: string | null
          id?: string
          key_hash?: string
          last_used_at?: string | null
          name?: string
          organization_id?: string
          prefix?: string
          revoked_at?: string | null
          scopes?: string[]
        }
        Relationships: [
          {
            foreignKeyName: "api_keys_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "api_keys_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      api_scopes: {
        Row: {
          description: string
          is_write: boolean
          scope: string
          sort_order: number
        }
        Insert: {
          description: string
          is_write?: boolean
          scope: string
          sort_order?: number
        }
        Update: {
          description?: string
          is_write?: boolean
          scope?: string
          sort_order?: number
        }
        Relationships: []
      }
      customers: {
        Row: {
          anonymized_at: string | null
          created_at: string
          email: string
          full_name: string | null
          id: string
          marketing_opt_in: boolean
          notes: string | null
          organization_id: string
          phone: string | null
          updated_at: string
        }
        Insert: {
          anonymized_at?: string | null
          created_at?: string
          email: string
          full_name?: string | null
          id?: string
          marketing_opt_in?: boolean
          notes?: string | null
          organization_id: string
          phone?: string | null
          updated_at?: string
        }
        Update: {
          anonymized_at?: string | null
          created_at?: string
          email?: string
          full_name?: string | null
          id?: string
          marketing_opt_in?: boolean
          notes?: string | null
          organization_id?: string
          phone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "customers_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      document_sections: {
        Row: {
          content: string
          created_at: string
          document_id: string
          embedding: string | null
          error: string | null
          id: string
          organization_id: string
          position: number
          search_vector: unknown
          status: Database["public"]["Enums"]["embedding_status"]
          token_count: number | null
          updated_at: string
        }
        Insert: {
          content: string
          created_at?: string
          document_id: string
          embedding?: string | null
          error?: string | null
          id?: string
          organization_id: string
          position?: number
          search_vector?: unknown
          status?: Database["public"]["Enums"]["embedding_status"]
          token_count?: number | null
          updated_at?: string
        }
        Update: {
          content?: string
          created_at?: string
          document_id?: string
          embedding?: string | null
          error?: string | null
          id?: string
          organization_id?: string
          position?: number
          search_vector?: unknown
          status?: Database["public"]["Enums"]["embedding_status"]
          token_count?: number | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "document_sections_document_id_organization_id_fkey"
            columns: ["document_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "documents"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      documents: {
        Row: {
          checksum: string | null
          content: string
          created_at: string
          created_by: string | null
          id: string
          metadata: Json
          organization_id: string
          source_id: string | null
          source_type: Database["public"]["Enums"]["document_source"]
          title: string
          updated_at: string
        }
        Insert: {
          checksum?: string | null
          content?: string
          created_at?: string
          created_by?: string | null
          id?: string
          metadata?: Json
          organization_id: string
          source_id?: string | null
          source_type?: Database["public"]["Enums"]["document_source"]
          title: string
          updated_at?: string
        }
        Update: {
          checksum?: string | null
          content?: string
          created_at?: string
          created_by?: string | null
          id?: string
          metadata?: Json
          organization_id?: string
          source_id?: string | null
          source_type?: Database["public"]["Enums"]["document_source"]
          title?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "documents_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "documents_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      ingredients: {
        Row: {
          allergens: string[]
          archived_at: string | null
          created_at: string
          created_by: string | null
          id: string
          name: string
          organization_id: string
          reorder_level: number
          sku: string
          unit: Database["public"]["Enums"]["unit_of_measure"]
          updated_at: string
        }
        Insert: {
          allergens?: string[]
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name: string
          organization_id: string
          reorder_level?: number
          sku: string
          unit: Database["public"]["Enums"]["unit_of_measure"]
          updated_at?: string
        }
        Update: {
          allergens?: string[]
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          name?: string
          organization_id?: string
          reorder_level?: number
          sku?: string
          unit?: Database["public"]["Enums"]["unit_of_measure"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ingredients_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ingredients_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      inventory_movements: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          ingredient_id: string
          kind: Database["public"]["Enums"]["stock_movement_kind"]
          note: string | null
          order_id: string | null
          organization_id: string
          quantity: number
          unit_cost_cents: number | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          ingredient_id: string
          kind: Database["public"]["Enums"]["stock_movement_kind"]
          note?: string | null
          order_id?: string | null
          organization_id: string
          quantity: number
          unit_cost_cents?: number | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          ingredient_id?: string
          kind?: Database["public"]["Enums"]["stock_movement_kind"]
          note?: string | null
          order_id?: string | null
          organization_id?: string
          quantity?: number
          unit_cost_cents?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_ingredient_id_organization_id_fkey"
            columns: ["ingredient_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      notifications: {
        Row: {
          body: string | null
          created_at: string
          data: Json
          id: string
          kind: Database["public"]["Enums"]["notification_kind"]
          organization_id: string | null
          read_at: string | null
          title: string
          url: string | null
          user_id: string
        }
        Insert: {
          body?: string | null
          created_at?: string
          data?: Json
          id?: string
          kind?: Database["public"]["Enums"]["notification_kind"]
          organization_id?: string | null
          read_at?: string | null
          title: string
          url?: string | null
          user_id: string
        }
        Update: {
          body?: string | null
          created_at?: string
          data?: Json
          id?: string
          kind?: Database["public"]["Enums"]["notification_kind"]
          organization_id?: string | null
          read_at?: string | null
          title?: string
          url?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notifications_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      order_items: {
        Row: {
          allergens_disclosed: string[]
          id: string
          line_total_cents: number | null
          name_at_purchase: string
          order_id: string
          organization_id: string
          product_id: string | null
          quantity: number
          sku_at_purchase: string
          unit_price_cents: number
        }
        Insert: {
          allergens_disclosed?: string[]
          id?: string
          line_total_cents?: number | null
          name_at_purchase: string
          order_id: string
          organization_id: string
          product_id?: string | null
          quantity: number
          sku_at_purchase: string
          unit_price_cents: number
        }
        Update: {
          allergens_disclosed?: string[]
          id?: string
          line_total_cents?: number | null
          name_at_purchase?: string
          order_id?: string
          organization_id?: string
          product_id?: string | null
          quantity?: number
          sku_at_purchase?: string
          unit_price_cents?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_items_order_id_organization_id_fkey"
            columns: ["order_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "order_items_product_id_organization_id_fkey"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      orders: {
        Row: {
          cancelled_at: string | null
          confirmed_at: string | null
          created_at: string
          currency: string
          customer_id: string
          id: string
          order_number: string
          organization_id: string
          placed_at: string
          status: Database["public"]["Enums"]["order_status"]
          total_cents: number
          updated_at: string
        }
        Insert: {
          cancelled_at?: string | null
          confirmed_at?: string | null
          created_at?: string
          currency: string
          customer_id: string
          id?: string
          order_number?: string
          organization_id: string
          placed_at?: string
          status?: Database["public"]["Enums"]["order_status"]
          total_cents?: number
          updated_at?: string
        }
        Update: {
          cancelled_at?: string | null
          confirmed_at?: string | null
          created_at?: string
          currency?: string
          customer_id?: string
          id?: string
          order_number?: string
          organization_id?: string
          placed_at?: string
          status?: Database["public"]["Enums"]["order_status"]
          total_cents?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "orders_customer_id_organization_id_fkey"
            columns: ["customer_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "orders_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_invites: {
        Row: {
          accepted_at: string | null
          accepted_by: string | null
          created_at: string
          email: string
          expires_at: string
          id: string
          invited_by: string | null
          organization_id: string
          revoked_at: string | null
          role: Database["public"]["Enums"]["org_role"]
          token_hash: string
        }
        Insert: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          email: string
          expires_at?: string
          id?: string
          invited_by?: string | null
          organization_id: string
          revoked_at?: string | null
          role?: Database["public"]["Enums"]["org_role"]
          token_hash: string
        }
        Update: {
          accepted_at?: string | null
          accepted_by?: string | null
          created_at?: string
          email?: string
          expires_at?: string
          id?: string
          invited_by?: string | null
          organization_id?: string
          revoked_at?: string | null
          role?: Database["public"]["Enums"]["org_role"]
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_invites_accepted_by_fkey"
            columns: ["accepted_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_invites_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_invites_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organization_members: {
        Row: {
          created_at: string
          invited_by: string | null
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          invited_by?: string | null
          organization_id: string
          role?: Database["public"]["Enums"]["org_role"]
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          invited_by?: string | null
          organization_id?: string
          role?: Database["public"]["Enums"]["org_role"]
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_members_invited_by_fkey"
            columns: ["invited_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_members_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "organization_members_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          billing_email: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          logo_path: string | null
          name: string
          settings: Json
          slug: string
          updated_at: string
          website: string | null
        }
        Insert: {
          billing_email?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          logo_path?: string | null
          name: string
          settings?: Json
          slug: string
          updated_at?: string
          website?: string | null
        }
        Update: {
          billing_email?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          logo_path?: string | null
          name?: string
          settings?: Json
          slug?: string
          updated_at?: string
          website?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "organizations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      plans: {
        Row: {
          billing_interval: string
          created_at: string
          currency: string
          description: string | null
          features: Json
          id: string
          is_public: boolean
          limits: Json
          name: string
          price_cents: number
          sort_order: number
          stripe_price_id: string | null
          updated_at: string
        }
        Insert: {
          billing_interval?: string
          created_at?: string
          currency?: string
          description?: string | null
          features?: Json
          id: string
          is_public?: boolean
          limits?: Json
          name: string
          price_cents?: number
          sort_order?: number
          stripe_price_id?: string | null
          updated_at?: string
        }
        Update: {
          billing_interval?: string
          created_at?: string
          currency?: string
          description?: string | null
          features?: Json
          id?: string
          is_public?: boolean
          limits?: Json
          name?: string
          price_cents?: number
          sort_order?: number
          stripe_price_id?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      product_ingredients: {
        Row: {
          created_at: string
          ingredient_id: string
          organization_id: string
          product_id: string
          quantity: number
        }
        Insert: {
          created_at?: string
          ingredient_id: string
          organization_id: string
          product_id: string
          quantity: number
        }
        Update: {
          created_at?: string
          ingredient_id?: string
          organization_id?: string
          product_id?: string
          quantity?: number
        }
        Relationships: [
          {
            foreignKeyName: "product_ingredients_ingredient_id_organization_id_fkey"
            columns: ["ingredient_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["id", "organization_id"]
          },
          {
            foreignKeyName: "product_ingredients_product_id_organization_id_fkey"
            columns: ["product_id", "organization_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id", "organization_id"]
          },
        ]
      }
      products: {
        Row: {
          allergens: string[]
          archived_at: string | null
          created_at: string
          created_by: string | null
          currency: string
          description: string | null
          id: string
          name: string
          organization_id: string
          price_cents: number
          search_vector: unknown
          sku: string
          status: Database["public"]["Enums"]["product_status"]
          updated_at: string
        }
        Insert: {
          allergens?: string[]
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          id?: string
          name: string
          organization_id: string
          price_cents: number
          search_vector?: unknown
          sku: string
          status?: Database["public"]["Enums"]["product_status"]
          updated_at?: string
        }
        Update: {
          allergens?: string[]
          archived_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          description?: string | null
          id?: string
          name?: string
          organization_id?: string
          price_cents?: number
          search_vector?: unknown
          sku?: string
          status?: Database["public"]["Enums"]["product_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "products_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_path: string | null
          created_at: string
          email: string
          full_name: string | null
          headline: string | null
          id: string
          is_admin: boolean
          last_seen_at: string | null
          locale: string
          onboarded_at: string | null
          preferences: Json
          timezone: string
          updated_at: string
        }
        Insert: {
          avatar_path?: string | null
          created_at?: string
          email: string
          full_name?: string | null
          headline?: string | null
          id: string
          is_admin?: boolean
          last_seen_at?: string | null
          locale?: string
          onboarded_at?: string | null
          preferences?: Json
          timezone?: string
          updated_at?: string
        }
        Update: {
          avatar_path?: string | null
          created_at?: string
          email?: string
          full_name?: string | null
          headline?: string | null
          id?: string
          is_admin?: boolean
          last_seen_at?: string | null
          locale?: string
          onboarded_at?: string | null
          preferences?: Json
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      subscriptions: {
        Row: {
          cancel_at_period_end: boolean
          canceled_at: string | null
          created_at: string
          current_period_end: string | null
          current_period_start: string | null
          limit_overrides: Json
          organization_id: string
          plan_id: string
          seats: number
          status: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id: string | null
          stripe_subscription_id: string | null
          trial_ends_at: string | null
          updated_at: string
        }
        Insert: {
          cancel_at_period_end?: boolean
          canceled_at?: string | null
          created_at?: string
          current_period_end?: string | null
          current_period_start?: string | null
          limit_overrides?: Json
          organization_id: string
          plan_id: string
          seats?: number
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          trial_ends_at?: string | null
          updated_at?: string
        }
        Update: {
          cancel_at_period_end?: boolean
          canceled_at?: string | null
          created_at?: string
          current_period_end?: string | null
          current_period_start?: string | null
          limit_overrides?: Json
          organization_id?: string
          plan_id?: string
          seats?: number
          status?: Database["public"]["Enums"]["subscription_status"]
          stripe_customer_id?: string | null
          stripe_subscription_id?: string | null
          trial_ends_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "subscriptions_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscriptions_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "plans"
            referencedColumns: ["id"]
          },
        ]
      }
      usage_daily: {
        Row: {
          day: string
          metric: Database["public"]["Enums"]["usage_metric"]
          organization_id: string
          quantity: number
          updated_at: string
        }
        Insert: {
          day: string
          metric: Database["public"]["Enums"]["usage_metric"]
          organization_id: string
          quantity?: number
          updated_at?: string
        }
        Update: {
          day?: string
          metric?: Database["public"]["Enums"]["usage_metric"]
          organization_id?: string
          quantity?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "usage_daily_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      usage_events: {
        Row: {
          id: number
          metadata: Json
          metric: Database["public"]["Enums"]["usage_metric"]
          occurred_at: string
          organization_id: string
          quantity: number
          subject_id: string | null
          subject_type: string | null
        }
        Insert: {
          id?: never
          metadata?: Json
          metric: Database["public"]["Enums"]["usage_metric"]
          occurred_at?: string
          organization_id: string
          quantity?: number
          subject_id?: string | null
          subject_type?: string | null
        }
        Update: {
          id?: never
          metadata?: Json
          metric?: Database["public"]["Enums"]["usage_metric"]
          occurred_at?: string
          organization_id?: string
          quantity?: number
          subject_id?: string | null
          subject_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "usage_events_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      webhook_endpoints: {
        Row: {
          created_at: string
          created_by: string | null
          description: string | null
          disabled_at: string | null
          events: string[]
          failure_count: number
          id: string
          is_active: boolean
          organization_id: string
          secret_id: string | null
          updated_at: string
          url: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          disabled_at?: string | null
          events?: string[]
          failure_count?: number
          id?: string
          is_active?: boolean
          organization_id: string
          secret_id?: string | null
          updated_at?: string
          url: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          description?: string | null
          disabled_at?: string | null
          events?: string[]
          failure_count?: number
          id?: string
          is_active?: boolean
          organization_id?: string
          secret_id?: string | null
          updated_at?: string
          url?: string
        }
        Relationships: [
          {
            foreignKeyName: "webhook_endpoints_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "webhook_endpoints_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      accept_organization_invite: {
        Args: { p_token: string }
        Returns: {
          created_at: string
          invited_by: string | null
          organization_id: string
          role: Database["public"]["Enums"]["org_role"]
          updated_at: string
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "organization_members"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      anonymize_customer: {
        Args: { p_customer_id: string }
        Returns: undefined
      }
      api_cancel_order: {
        Args: {
          p_order_number: string
          p_organization_id: string
          p_reason?: string
        }
        Returns: Json
      }
      api_get_order: {
        Args: { p_order_number: string; p_organization_id: string }
        Returns: Json
      }
      api_get_product: {
        Args: { p_organization_id: string; p_sku: string }
        Returns: Json
      }
      api_key_activity: {
        Args: { p_key_id: string; p_limit?: number }
        Returns: {
          created_at: string
          outcome: string
          scope_required: string
        }[]
      }
      api_list_orders: {
        Args: {
          p_before?: string
          p_limit?: number
          p_organization_id: string
          p_status?: Database["public"]["Enums"]["order_status"]
        }
        Returns: Json
      }
      api_list_products: {
        Args: {
          p_before?: string
          p_limit?: number
          p_organization_id: string
          p_status?: Database["public"]["Enums"]["product_status"]
        }
        Returns: Json
      }
      api_place_order: {
        Args: {
          p_customer_email: string
          p_lines: Json
          p_organization_id: string
        }
        Returns: Json
      }
      api_recall_report: {
        Args: {
          p_allergen: string
          p_organization_id: string
          p_since?: string
        }
        Returns: Json
      }
      api_record_movement: {
        Args: {
          p_kind: Database["public"]["Enums"]["stock_movement_kind"]
          p_note?: string
          p_organization_id: string
          p_quantity: number
          p_sku: string
          p_unit_cost_cents?: number
        }
        Returns: Json
      }
      api_remember_idempotent: {
        Args: {
          p_fingerprint: string
          p_idempotency_key: string
          p_key_id: string
          p_response: Json
          p_status_code?: number
        }
        Returns: undefined
      }
      api_replay_idempotent: {
        Args: {
          p_fingerprint: string
          p_idempotency_key: string
          p_key_id: string
        }
        Returns: Json
      }
      api_set_recipe: {
        Args: { p_lines: Json; p_organization_id: string; p_sku: string }
        Returns: Json
      }
      api_stock_levels: {
        Args: { p_below_reorder_level?: boolean; p_organization_id: string }
        Returns: Json
      }
      api_upsert_customer: {
        Args: {
          p_email: string
          p_full_name?: string
          p_marketing_opt_in?: boolean
          p_organization_id: string
          p_phone?: string
        }
        Returns: Json
      }
      api_upsert_document: {
        Args: {
          p_content: string
          p_organization_id: string
          p_source_id: string
          p_title: string
        }
        Returns: Json
      }
      api_upsert_ingredient: {
        Args: {
          p_allergens?: string[]
          p_name: string
          p_organization_id: string
          p_reorder_level?: number
          p_sku: string
          p_unit: Database["public"]["Enums"]["unit_of_measure"]
        }
        Returns: Json
      }
      api_upsert_product: {
        Args: {
          p_currency?: string
          p_description?: string
          p_name: string
          p_organization_id: string
          p_price_cents: number
          p_sku: string
          p_status?: Database["public"]["Enums"]["product_status"]
        }
        Returns: Json
      }
      audit_trail: {
        Args: { p_before?: string; p_limit?: number; p_organization_id: string }
        Returns: {
          action: string
          actor_email: string
          actor_id: string
          changed_fields: string[]
          created_at: string
          id: number
          record_id: string
          table_name: string
        }[]
      }
      authenticate_api_key: {
        Args: { p_key: string; p_required_scope?: string }
        Returns: Json
      }
      cancel_order: {
        Args: {
          p_order_id: string
          p_organization_id: string
          p_reason?: string
        }
        Returns: Json
      }
      create_api_key: {
        Args: {
          p_expires_in?: string
          p_name: string
          p_organization_id: string
          p_scopes?: string[]
        }
        Returns: {
          api_key: string
          key_id: string
          key_prefix: string
        }[]
      }
      create_organization: {
        Args: { p_name: string; p_slug?: string }
        Returns: {
          billing_email: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          logo_path: string | null
          name: string
          settings: Json
          slug: string
          updated_at: string
          website: string | null
        }
        SetofOptions: {
          from: "*"
          to: "organizations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      create_organization_invite: {
        Args: {
          p_email: string
          p_organization_id: string
          p_role?: Database["public"]["Enums"]["org_role"]
        }
        Returns: {
          invite_id: string
          token: string
        }[]
      }
      get_order: {
        Args: { p_order_id: string; p_organization_id: string }
        Returns: Json
      }
      hybrid_search_documents: {
        Args: {
          p_embedding: string
          p_match_count?: number
          p_organization_id: string
          p_query: string
          p_rrf_k?: number
        }
        Returns: {
          content: string
          document_id: string
          id: string
          score: number
        }[]
      }
      ingredient_available: {
        Args: { p_ingredient_id: string }
        Returns: number
      }
      mark_notifications_read: { Args: { p_ids?: string[] }; Returns: number }
      match_document_sections: {
        Args: {
          p_embedding: string
          p_match_count?: number
          p_min_similarity?: number
          p_organization_id: string
        }
        Returns: {
          content: string
          document_id: string
          id: string
          similarity: number
        }[]
      }
      my_auth_events: {
        Args: { p_limit?: number }
        Returns: {
          created_at: string
          kind: string
          succeeded: boolean
        }[]
      }
      orders_missing_allergen: {
        Args: {
          p_allergen: string
          p_organization_id: string
          p_since?: string
        }
        Returns: Json
      }
      organization_overview: {
        Args: { p_organization_id: string }
        Returns: Json
      }
      place_order: {
        Args: {
          p_customer_id: string
          p_lines: Json
          p_organization_id: string
        }
        Returns: Json
      }
      product_sellable: { Args: { p_product_id: string }; Returns: number }
      queue_archive: {
        Args: { p_msg_id: number; p_queue: string }
        Returns: boolean
      }
      queue_delete: {
        Args: { p_msg_id: number; p_queue: string }
        Returns: boolean
      }
      queue_read: {
        Args: {
          p_count?: number
          p_queue: string
          p_visibility_seconds?: number
        }
        Returns: {
          enqueued_at: string
          message: Json
          msg_id: number
          read_ct: number
        }[]
      }
      replace_document_sections: {
        Args: { p_document_id: string; p_sections: string[] }
        Returns: number
      }
      revoke_api_key: { Args: { p_key_id: string }; Returns: undefined }
      rollup_usage: { Args: { p_day?: string }; Returns: number }
      rotate_api_key: {
        Args: { p_grace?: string; p_key_id: string }
        Returns: {
          api_key: string
          key_id: string
          key_prefix: string
        }[]
      }
      touch_last_seen: { Args: never; Returns: undefined }
      transfer_organization_ownership: {
        Args: { p_organization_id: string; p_to_user_id: string }
        Returns: undefined
      }
      webhook_delivery_log: {
        Args: { p_endpoint_id: string; p_limit?: number }
        Returns: {
          attempts: number
          created_at: string
          event: string
          id: string
          last_error: string
          response_status: number
          status: string
        }[]
      }
    }
    Enums: {
      document_source: "demo" | "help_article" | "upload" | "note" | "product"
      embedding_status: "pending" | "processing" | "ready" | "failed"
      notification_kind:
        | "comment"
        | "mention"
        | "invite"
        | "demo_published"
        | "quota_warning"
        | "billing"
        | "system"
      order_status: "pending" | "confirmed" | "fulfilled" | "cancelled"
      org_role: "viewer" | "member" | "admin" | "owner"
      product_status: "draft" | "active" | "discontinued"
      stock_movement_kind:
        | "receipt"
        | "consumption"
        | "waste"
        | "adjustment"
        | "release"
      subscription_status:
        | "trialing"
        | "active"
        | "past_due"
        | "canceled"
        | "incomplete"
        | "paused"
      unit_of_measure: "g" | "ml" | "unit"
      usage_metric:
        | "demo_view"
        | "demo_created"
        | "ai_embedding"
        | "storage_bytes"
        | "api_call"
        | "email_sent"
        | "order_placed"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  api: {
    Enums: {},
  },
  public: {
    Enums: {
      document_source: ["demo", "help_article", "upload", "note", "product"],
      embedding_status: ["pending", "processing", "ready", "failed"],
      notification_kind: [
        "comment",
        "mention",
        "invite",
        "demo_published",
        "quota_warning",
        "billing",
        "system",
      ],
      order_status: ["pending", "confirmed", "fulfilled", "cancelled"],
      org_role: ["viewer", "member", "admin", "owner"],
      product_status: ["draft", "active", "discontinued"],
      stock_movement_kind: [
        "receipt",
        "consumption",
        "waste",
        "adjustment",
        "release",
      ],
      subscription_status: [
        "trialing",
        "active",
        "past_due",
        "canceled",
        "incomplete",
        "paused",
      ],
      unit_of_measure: ["g", "ml", "unit"],
      usage_metric: [
        "demo_view",
        "demo_created",
        "ai_embedding",
        "storage_bytes",
        "api_call",
        "email_sent",
        "order_placed",
      ],
    },
  },
} as const

