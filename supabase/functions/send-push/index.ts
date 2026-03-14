import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

serve(async (req) => {
  try {
    const data = await req.json();

    const res = await fetch("https://api.pushbullet.com/v2/pushes", {
      method: "POST",
      headers: {
        "Access-Token": Deno.env.get("PUSHBULLET_TOKEN")!,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(data),
    });

    const result = await res.text();

    return new Response(result, {
      headers: { "Content-Type": "application/json" },
      status: res.status,
    });

  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500 }
    );
  }
});