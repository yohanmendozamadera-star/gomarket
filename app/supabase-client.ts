import { createClient } from "@supabase/supabase-js";

const supabaseUrl = "https://mksyohgdllgysmcxjtvf.supabase.co";
const supabasePublishableKey = "sb_publishable_G5BklxSGSJdatQfmTsXhHg_9Rc4TbQH";

export const supabase = createClient(supabaseUrl, supabasePublishableKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
