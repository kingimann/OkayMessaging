// Native Connect onboarding: what Stripe still needs, and taking it.
//
// WHY THIS EXISTS. Setting up payments used to mean one of Stripe's own web
// pages — the hosted flow or the embedded component — because the accounts were
// created as `express`, and Stripe does not let a platform collect an Express
// account's KYC over the API. That is not a limitation anybody can code around:
// it is the account type. So payments could never be integrated the way the rest
// of this app is, and the setup screen always looked like somebody else's page.
//
// Accounts are created here with `controller.requirement_collection:
// "application"`, which means THIS application collects the requirements. Then
// the fields can be asked for in the app's own forms and submitted over the
// API — no hosted page, no iframe, no browser.
//
// WHAT THAT COSTS, PLAINLY: with requirement collection on the application, the
// platform also takes `losses.payments: "application"` — disputes and negative
// balances land on the platform, not on Stripe. That is the trade for native
// onboarding and it is a business decision, not a technical one.
//
// WHAT NEVER REACHES THIS FUNCTION: bank account numbers and government ID
// numbers. The app tokenises those against Stripe directly with the publishable
// key, and sends only the resulting `btok_…` / `piitok_…`. So the one server in
// this system never sees them, which is the same rule the rest of the app
// follows.
//
// POST {}                    -> { accountId, collection, currentlyDue, pastDue,
//                                 errors, status, country, currency }
// POST { submit: {...} }      -> the same, after applying the submission
// POST { replaceAccount: true } -> abandons an account Stripe will only onboard
//                                 on its own pages, and makes one this app can
//                                 collect for. Asked for explicitly.

import { admin, callerPhone, corsHeaders, json } from "../_shared/http.ts";
import { stripe } from "../_shared/stripe.ts";

/// Requirements this app has a form for. Anything else is reported to the
/// client as unhandled rather than silently dropped — a requirement nobody
/// collects is an account that never activates, and the user deserves to be
/// told which.
const HANDLED = new Set([
  "individual.first_name",
  "individual.last_name",
  "individual.dob.day",
  "individual.dob.month",
  "individual.dob.year",
  "individual.address.line1",
  "individual.address.line2",
  "individual.address.city",
  "individual.address.state",
  "individual.address.postal_code",
  "individual.address.country",
  "individual.email",
  "individual.phone",
  "individual.id_number",
  "individual.ssn_last_4",
  "external_account",
  "individual.verification.document",
  "individual.verification.additional_document",
  "tos_acceptance.date",
  "tos_acceptance.ip",
  "business_profile.mcc",
  "business_profile.product_description",
  "business_profile.url",
  "business_type",
]);

/// Whether a connected account is an Express leftover worth throwing away.
///
/// An Express account can only be onboarded on Stripe's own pages, so keeping
/// one means the app has to send somebody out to a web form — the exact seam
/// this function exists to remove. But an Express account that has been *used*
/// is somebody's real payment account, with a history and possibly a balance,
/// and abandoning it would be destroying something.
///
/// So: replace it only when it holds nothing. Nothing submitted, no charges, no
/// payouts — an account that was created, never finished, and is worth exactly
/// zero. Anything else is kept and the hosted flow is offered for it honestly.
export function isDiscardableExpressAccount(account: {
  controller?: { requirement_collection?: string } | null;
  details_submitted?: boolean | null;
  charges_enabled?: boolean | null;
  payouts_enabled?: boolean | null;
}): boolean {
  const collectedByStripe =
    (account.controller?.requirement_collection ?? "stripe") !== "application";
  return collectedByStripe &&
    !account.details_submitted &&
    !account.charges_enabled &&
    !account.payouts_enabled;
}

type Submission = {
  firstName?: string;
  lastName?: string;
  email?: string;
  phone?: string;
  dob?: { day: number; month: number; year: number };
  address?: {
    line1?: string;
    line2?: string;
    city?: string;
    state?: string;
    postalCode?: string;
    country?: string;
  };
  // Tokens minted on the device with the publishable key. Raw numbers must
  // never appear here; the checks below refuse them if they do.
  idNumberToken?: string;
  ssnLast4?: string;
  bankToken?: string;
  // Ids of files already uploaded to Stripe FROM THE DEVICE. The photo of
  // somebody's licence never passes through here either.
  documentFrontFileId?: string;
  documentBackFileId?: string;
  productDescription?: string;
  mcc?: string;
  acceptedTos?: boolean;
};

function describe(account: Record<string, unknown>) {
  const req = (account.requirements ?? {}) as Record<string, unknown>;
  const currentlyDue = (req.currently_due ?? []) as string[];
  const pastDue = (req.past_due ?? []) as string[];
  const errors = ((req.errors ?? []) as { requirement: string; reason: string }[])
    .map((e) => ({ requirement: e.requirement, reason: e.reason }));
  const controller = (account.controller ?? {}) as Record<string, unknown>;
  return {
    accountId: account.id,
    // 'application' means the fields can be collected in the app. 'stripe'
    // means this is an older Express account and only Stripe's own pages can
    // onboard it — the client then uses the hosted flow, honestly, rather than
    // presenting a form that cannot work.
    collection: controller.requirement_collection ?? "stripe",
    currentlyDue,
    pastDue,
    unhandled: currentlyDue.filter((r) => !HANDLED.has(r)),
    errors,
    country: account.country,
    currency: (account.default_currency ?? "").toString(),
    status: {
      chargesEnabled: account.charges_enabled,
      payoutsEnabled: account.payouts_enabled,
      detailsSubmitted: account.details_submitted,
      disabledReason: ((account.requirements ?? {}) as Record<string, unknown>)
        .disabled_reason ?? null,
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const phone = await callerPhone(req);
  if (!phone) return json({ error: "unauthorized" }, 401);

  let body: { submit?: Submission; replaceAccount?: boolean } = {};
  try {
    body = await req.json();
  } catch (_) {
    // An empty body is the "just tell me what is needed" call.
  }

  try {
    const { data: existing } = await admin
      .from("payment_accounts")
      .select("stripe_account_id")
      .eq("phone", phone)
      .maybeSingle();

    let accountId = existing?.stripe_account_id as string | undefined;

    // A stored id from the other key mode is real but invisible under this key;
    // Stripe answers "No such account". Forget it and make one that belongs
    // here. Only on resource_missing — a network blip must not discard an
    // account somebody has already put their details into.
    // An unused Express account is the last thing standing between somebody
    // and setting payments up without leaving the app, so it goes.
    let replacedStaleAccount = false;

    // Asked for by name, from the screen that would otherwise be a dead end:
    // an account Stripe will only onboard on its own pages, and somebody who
    // wants it done in the app. The account is abandoned, not deleted — it stays
    // in the Stripe dashboard — and a fresh one takes its place.
    //
    // Refused for an account that can actually move money. Payouts enabled means
    // a real, working payment account, and swapping that out from under somebody
    // could strand a payout in flight. Everything short of that is a half-made
    // account worth nothing.
    if (body.replaceAccount && accountId) {
      const current = await stripe.accounts.retrieve(accountId);
      if ((current.controller?.requirement_collection ?? "stripe") ===
          "application") {
        // Already collectable here; nothing to replace.
      } else if (current.payouts_enabled) {
        return json({
          error: "account_in_use: this payment account can already receive " +
            "payouts, so it is not replaced. Finish on Stripe's page, or " +
            "remove the account in the Stripe dashboard first.",
        }, 400);
      } else {
        await admin.from("payment_accounts").delete().eq("phone", phone);
        accountId = undefined;
        replacedStaleAccount = true;
      }
    }

    if (accountId) {
      try {
        const stored = await stripe.accounts.retrieve(accountId);
        if (isDiscardableExpressAccount(
          stored as unknown as Parameters<typeof isDiscardableExpressAccount>[0],
        )) {
          await admin.from("payment_accounts").delete().eq("phone", phone);
          accountId = undefined;
          replacedStaleAccount = true;
        }
      } catch (e) {
        const err = e as { code?: string; statusCode?: number };
        if (err?.code === "resource_missing" || err?.statusCode === 404) {
          await admin.from("payment_accounts").delete().eq("phone", phone);
          accountId = undefined;
        } else {
          throw e;
        }
      }
    }

    if (!accountId) {
      const created = await stripe.accounts.create({
        country: Deno.env.get("CONNECT_COUNTRY") ?? "CA",
        business_type: "individual",
        controller: {
          // This application collects the requirements, which is what makes a
          // native form legal to use at all.
          requirement_collection: "application",
          fees: { payer: "application" },
          losses: { payments: "application" },
          // No Stripe-hosted dashboard for the recipient: everything they need
          // is in this app.
          stripe_dashboard: { type: "none" },
        },
        capabilities: {
          card_payments: { requested: true },
          transfers: { requested: true },
        },
        metadata: { phone },
      });
      accountId = created.id;
      await admin.from("payment_accounts").upsert({
        phone,
        stripe_account_id: accountId,
        updated_at: new Date().toISOString(),
      });
    }

    const submit = body.submit;
    if (submit) {
      // Refuse raw secrets outright rather than forwarding them. If a future
      // client ever sends an account number here by mistake, this is the line
      // that stops it reaching Stripe's logs through our server.
      if (submit.bankToken && !submit.bankToken.startsWith("btok_")) {
        return json({
          error: "bank_details_must_be_tokenised: send a btok_ from the device, " +
            "never an account number",
        }, 400);
      }
      if (submit.idNumberToken && !submit.idNumberToken.startsWith("piitok_")) {
        return json({
          error: "id_number_must_be_tokenised: send a piitok_ from the device",
        }, 400);
      }
      for (
        const id of [submit.documentFrontFileId, submit.documentBackFileId]
      ) {
        if (id && !id.startsWith("file_")) {
          return json({
            error: "document_must_be_uploaded_from_the_device: send a file_ id, " +
              "never image bytes",
          }, 400);
        }
      }

      const individual: Record<string, unknown> = {};
      if (submit.firstName) individual.first_name = submit.firstName;
      if (submit.lastName) individual.last_name = submit.lastName;
      if (submit.email) individual.email = submit.email;
      if (submit.phone) individual.phone = submit.phone;
      if (submit.dob) individual.dob = submit.dob;
      if (submit.idNumberToken) individual.id_number = submit.idNumberToken;
      if (submit.ssnLast4) individual.ssn_last_4 = submit.ssnLast4;
      if (submit.address) {
        const a = submit.address;
        individual.address = {
          ...(a.line1 ? { line1: a.line1 } : {}),
          ...(a.line2 ? { line2: a.line2 } : {}),
          ...(a.city ? { city: a.city } : {}),
          ...(a.state ? { state: a.state } : {}),
          ...(a.postalCode ? { postal_code: a.postalCode } : {}),
          ...(a.country ? { country: a.country } : {}),
        };
      }

      if (submit.documentFrontFileId || submit.documentBackFileId) {
        individual.verification = {
          document: {
            ...(submit.documentFrontFileId
              ? { front: submit.documentFrontFileId }
              : {}),
            ...(submit.documentBackFileId
              ? { back: submit.documentBackFileId }
              : {}),
          },
        };
      }

      const update: Record<string, unknown> = {};
      if (Object.keys(individual).length) update.individual = individual;
      if (submit.productDescription || submit.mcc) {
        update.business_profile = {
          ...(submit.mcc ? { mcc: submit.mcc } : {}),
          ...(submit.productDescription
            ? { product_description: submit.productDescription }
            : {}),
        };
      }
      if (submit.acceptedTos) {
        // Stripe requires the moment and the IP of the acceptance. Both come
        // from here rather than from the client: a client-supplied IP is not
        // evidence of anything.
        update.tos_acceptance = {
          date: Math.floor(Date.now() / 1000),
          ip: req.headers.get("x-forwarded-for")?.split(",")[0].trim() ??
            req.headers.get("cf-connecting-ip") ?? "0.0.0.0",
        };
      }
      if (Object.keys(update).length) {
        await stripe.accounts.update(accountId, update);
      }
      // The bank account goes on separately: it is an external account, not a
      // field of the person.
      if (submit.bankToken) {
        await stripe.accounts.createExternalAccount(accountId, {
          external_account: submit.bankToken,
        });
      }
    }

    const account = await stripe.accounts.retrieve(accountId);
    const out = {
      ...describe(account as unknown as Record<string, unknown>),
      // True when an unused Express account was thrown away for this one. Not
      // an error — but the app should not pretend nothing happened either.
      replacedStaleAccount,
    };
    await admin.from("payment_accounts").update({
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      updated_at: new Date().toISOString(),
    }).eq("phone", phone);
    return json(out);
  } catch (e) {
    const err = e as { message?: string; param?: string; code?: string };
    return json({
      error: String(err.message ?? e),
      param: err.param ?? null,
      code: err.code ?? null,
    }, 400);
  }
});
