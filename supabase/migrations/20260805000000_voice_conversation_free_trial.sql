-- 20260805000000_voice_conversation_free_trial.sql
-- Adds voice_conversation_free_trial_used column to user_settings.
-- Used by VoiceConversationAdGate to track per-user free conversation trial count.
ALTER TABLE public.user_settings
ADD COLUMN IF NOT EXISTS voice_conversation_free_trial_used INTEGER NOT NULL DEFAULT 0;
