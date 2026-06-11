import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.38.4";
import admin from "npm:firebase-admin@11.11.0";

// --- Constants ---
const TABLE_CONNECTION_REQUESTS = "connection_requests";
const TABLE_MESSAGES_PREFIX = "messages";
const NOTIFICATION_TYPE_CALL_INVITE = "CALL_INVITE";
const NOTIFICATION_TYPE_CONNECTION_REQUEST = "CONNECTION_REQUEST";
const NOTIFICATION_TYPE_MESSAGE = "MESSAGE";

// --- Environment Variable Validation ---
const FIREBASE_SERVICE_ACCOUNT = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

// --- Firebase Admin Initialization ---
// Initialize outside the request handler to avoid re-initialization on every call
try {
  if (admin.apps.length === 0 && FIREBASE_SERVICE_ACCOUNT) {
    const serviceAccount = JSON.parse(FIREBASE_SERVICE_ACCOUNT);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
    console.log("Firebase Admin initialized successfully.");
  }
} catch (error) {
  console.error("Failed to initialize Firebase Admin:", error);
}

// --- Helper Functions ---

async function getReceiverFcmToken(
  supabase: SupabaseClient,
  receiverId: string
): Promise<string | null> {
  const { data, error } = await supabase
    .from("profiles")
    .select("fcm_token")
    .eq("id", receiverId)
    .single();

  if (error) {
    console.log(
      `Error fetching receiver profile for ${receiverId}:`,
      error.message
    );
    return null;
  }
  if (!data?.fcm_token) {
    console.log(`Receiver ${receiverId} has no FCM token.`);
    return null;
  }
  return data.fcm_token;
}

async function getAuthorName(
  supabase: SupabaseClient,
  authorId: string
): Promise<string> {
  const { data } = await supabase
    .from("profiles")
    .select("full_name, username")
    .eq("id", authorId)
    .single();
  return data?.full_name || data?.username || "Someone";
}

serve(async (req) => {
  // 0. Check for required configurations
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error("Supabase URL or Service Role Key is not set.");
    return new Response("Server configuration error", { status: 500 });
  }
  if (admin.apps.length === 0) {
    console.error(
      "Firebase Admin not initialized. Cannot send push notifications."
    );
    return new Response("Firebase Admin not initialized", { status: 500 });
  }

  try {
    // 1. Verify webhook secret (highly recommended for security)
    // const signature = req.headers.get("X-Supabase-Signature");
    // ... verify signature ...

    // 2. Parse the webhook payload
    const payload = await req.json();
    console.log("Webhook payload:", payload);

    if (payload.type !== "INSERT" && payload.type !== "UPDATE") {
      return new Response("Ignored: not an INSERT or UPDATE event", { status: 200 });
    }

    const isMessage =
      payload.table === TABLE_MESSAGES_PREFIX ||
      payload.table.startsWith(`${TABLE_MESSAGES_PREFIX}_`);
    const isConnectionRequest = payload.table === TABLE_CONNECTION_REQUESTS;

    if (!isMessage && !isConnectionRequest) {
      return new Response(`Ignored: table '${payload.table}'`, { status: 200 });
    }

    let targetReceiverId: string;
    let targetAuthorId: string;

    if (isConnectionRequest) {
      if (payload.type === "INSERT") {
        targetReceiverId = record.receiver_id;
        targetAuthorId = record.sender_id;
      } else if (payload.type === "UPDATE" && record.status === "accepted") {
        // If accepted, notify the original sender
        targetReceiverId = record.sender_id;
        targetAuthorId = record.receiver_id;
      } else {
        return new Response("Ignored: Unhandled UPDATE state", { status: 200 });
      }
    } else {
      // isMessage
      if (payload.type !== "INSERT") {
        return new Response("Ignored: Messages only trigger on INSERT", { status: 200 });
      }
      
      const text = record.text || "";
      if (text.startsWith("RECEIPT_") || text.startsWith("DELETE_") || text.startsWith("EDIT_")) {
        return new Response("Ignored: Control message", { status: 200 });
      }
      
      targetReceiverId = record.receiver_id;
      targetAuthorId = record.author_id;
    }

    if (!targetReceiverId || !targetAuthorId) {
      return new Response("Missing target receiver or author", {
        status: 400,
      });
    }

    // 3. Initialize Supabase client
    const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const fcmToken = await getReceiverFcmToken(supabaseAdmin, targetReceiverId);
    if (!fcmToken) {
      return new Response("Receiver FCM token not found", { status: 200 });
    }

    const authorName = await getAuthorName(supabaseAdmin, targetAuthorId);

    let messagePayload;

    // 4. Construct the correct notification payload based on the event
    if (isConnectionRequest) {
      if (payload.type === "INSERT") {
        messagePayload = {
          token: fcmToken,
          notification: {
            title: "Connection Request",
            body: `${authorName} wants to connect with you.`,
          },
          data: {
            type: NOTIFICATION_TYPE_CONNECTION_REQUEST,
            id: String(record.id),
            author_id: targetAuthorId,
          },
          android: { priority: "high" },
        };
      } else {
        messagePayload = {
          token: fcmToken,
          notification: {
            title: "Connection Accepted! 🎉",
            body: `${authorName} accepted your connection request!`,
          },
          data: {
            type: NOTIFICATION_TYPE_CONNECTION_REQUEST,
            id: String(record.id),
            author_id: targetAuthorId,
          },
          android: { priority: "high" },
        };
      }
      console.log(`Sending connection push to ${targetReceiverId}`);
    } else {
      // isMessage
      const isCall = record.text?.startsWith("CALL_INVITE_");

      if (isCall) {
        // Send data-only payload for calls for immediate client-side handling
        messagePayload = {
          token: fcmToken,
          data: {
            type: NOTIFICATION_TYPE_CALL_INVITE,
            id: String(record.id),
            author_id: targetAuthorId,
            caller_name: authorName,
            text: record.text,
          },
          android: {
            priority: "high",
            ttl: 0,
          },
          apns: {
            headers: {
              "apns-priority": "10",
              "apns-expiration": "0"
            },
            payload: { aps: { "content-available": 1 } }
          },
        };
        console.log(`Sending call invite push to ${targetReceiverId}`);
      } else {
        // Standard notification for chat messages
        const body = record.text?.startsWith("[IMAGE]:")
          ? "Sent an image"
          : record.text;
        messagePayload = {
          token: fcmToken,
          notification: {
            title: authorName,
            body: body,
          },
          data: {
            type: NOTIFICATION_TYPE_MESSAGE,
            id: String(record.id),
            author_id: targetAuthorId,
          },
          android: { priority: "high" },
        };
        console.log(`Sending message push to ${targetReceiverId}`);
      }
    }

    // 5. Send the notification
    await admin.messaging().send(messagePayload);
    console.log("Push notification sent successfully.");

    return new Response("Success", { status: 200 });
  } catch (error) {
    console.error("Error processing webhook:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
