import { serve } from "https://deno.land/std/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js"

serve(async () => {

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  )

  const { data, error } = await supabase
    .from("categories")
    .select("*")

  if (error) {
    return new Response(JSON.stringify(error), { status: 500 })
  }

  return new Response(
    JSON.stringify(data),
    { headers: { "Content-Type": "application/json" } }
  )

})