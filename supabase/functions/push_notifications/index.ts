import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import admin from "npm:firebase-admin@11.11.0";

const serviceAccountStr = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
if (!serviceAccountStr) {
  console.error("FIREBASE_SERVICE_ACCOUNT environment variable is not set.");
} else {
  try {
    const serviceAccount = JSON.parse(serviceAccountStr);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
    console.log("Firebase Admin initialized successfully.");
  } catch (error) {
    console.error("Failed to parse FIREBASE_SERVICE_ACCOUNT:", error);
  }
}

serve(async (req) => {
  try {
    // 1. Verify webhook secret or authorization if needed
    // (You should set up a webhook secret in Supabase dashboard and verify it here)

    // 2. Parse the webhook payload
    const payload = await req.json();
    console.log("Webhook payload:", payload);

    if (payload.type === "INSERT") {
      const isMessage = payload.table === "messages" || payload.table.startsWith("messages_");
      const isConnectionRequest = payload.table === "connection_requests";
      
      if (!isMessage && !isConnectionRequest) {
        return new Response("Ignored table", { status: 200 });
      }

      const record = payload.record;
      if (!record) return new Response("No record found", { status: 400 });

      // 3. Initialize Supabase client to fetch the receiver's FCM token
      const supabaseAdmin = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
      );

      const receiverId = record.receiver_id;
      const authorId = isConnectionRequest ? record.sender_id : record.author_id;

      if (!receiverId || !authorId) {
        return new Response("Missing receiver_id or author_id", { status: 400 });
      }

      // Fetch the receiver's profile
      const { data: receiverProfile, error: receiverError } = await supabaseAdmin
        .from("profiles")
        .select("fcm_token")
        .eq("id", receiverId)
        .single();

      if (receiverError || !receiverProfile?.fcm_token) {
        console.log("Receiver FCM token not found or error:", receiverError);
        return new Response("Receiver has no FCM token", { status: 200 });
      }

      // Fetch the author's profile
      const { data: authorProfile } = await supabaseAdmin
        .from("profiles")
        .select("full_name, username")
        .eq("id", authorId)
        .single();

      const callerName = authorProfile?.full_name || authorProfile?.username || "Someone";
      
      let title = "New Message";
      let body = "";

      if (isConnectionRequest) {
        title = "Connection Request";
        body = `${callerName} wants to connect with you.`;
      } else {
        const isCall = record.text?.startsWith("CALL_INVITE_");
        body = record.text?.startsWith("[IMAGE]:") ? "Sent an image" : record.text;

        if (isCall) {
          title = "Incoming Call";
          body = `${callerName} is calling you.`;
          // Send data-only payload for calls
          const messagePayload = {
            token: receiverProfile.fcm_token,
            data: {
              type: "CALL_INVITE",
              id: record.id,
              author_id: authorId,
              caller_name: callerName,
              text: record.text,
            },
            android: { priority: "high" },
            apns: { payload: { aps: { "content-available": 1 } } },
          };
  
          await admin.messaging().send(messagePayload);
          console.log("Sent data-only push notification for Call");
          return new Response("Call push sent", { status: 200 });
        }
      }

      // 4. Send standard notification for chat messages & connection requests
      const messagePayload = {
        token: receiverProfile.fcm_token,
        notification: {
          title: isConnectionRequest ? title : callerName,
          body: body,
        },
        data: {
          type: isConnectionRequest ? "CONNECTION_REQUEST" : "MESSAGE",
          id: record.id || "0",
          author_id: authorId,
        },
      };

      await admin.messaging().send(messagePayload);
      console.log("Sent standard push notification for Message");

      return new Response("Success", { status: 200 });
    }

    return new Response("Ignored payload", { status: 200 });
  } catch (error) {
    console.error("Error processing webhook:", error);
    return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
