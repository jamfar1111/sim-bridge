package com.simbridge.sim_bridge

import android.content.ContentProviderOperation
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/** Contacts + call log. Port of Tether's `data/ContactsRepo.kt` and `data/DeviceRepo.kt` (CallLogRepo). */
class ContactsRepo(private val ctx: Context) {
    private val cr get() = ctx.contentResolver

    /** Hash of every raw contact's (id, version); changes whenever any contact changes. */
    fun version(): String {
        val md = MessageDigest.getInstance("SHA-1")
        try {
            cr.query(RawContacts.CONTENT_URI, arrayOf(RawContacts._ID, RawContacts.VERSION),
                "${RawContacts.DELETED} = 0", null, RawContacts._ID)?.use { c ->
                while (c.moveToNext()) md.update("${c.getLong(0)}:${c.getLong(1)};".toByteArray())
            }
        } catch (e: SecurityException) {
            return ""
        }
        return md.digest().joinToString("") { "%02x".format(it) }.take(16)
    }

    /** All contacts, in the JSON shape of Dart's `Contact` (`lib/src/protocol/messages.dart`). */
    fun all(withPhotos: Boolean = true): List<Map<String, Any?>> {
        val byId = LinkedHashMap<Long, Builder>()
        try {
            cr.query(Data.CONTENT_URI,
                arrayOf(Data.CONTACT_ID, Data.MIMETYPE, Data.DISPLAY_NAME_PRIMARY, Data.DATA1, Data.DATA2, Data.DATA3,
                    Data.STARRED, Data.PHOTO_THUMBNAIL_URI),
                "${Data.MIMETYPE} IN (?, ?)", arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE),
                "${Data.DISPLAY_NAME_PRIMARY} COLLATE LOCALIZED ASC")?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val b = byId.getOrPut(id) {
                        Builder(id, c.getString(2) ?: "", c.getInt(6) != 0, c.getString(7))
                    }
                    when (c.getString(1)) {
                        Phone.CONTENT_ITEM_TYPE -> c.getString(3)?.let { n ->
                            // One entry per number however it is written (update() matches numbers the same way).
                            if (b.phones.none { it["n"] == n || numberKey(it["n"] as String).let { k -> k.isNotEmpty() && k == numberKey(n) } }) {
                                b.phones.add(mapOf("n" to n, "type" to phoneType(c.getInt(4))).let {
                                    val m = it.toMutableMap()
                                    c.getString(5)?.let { label -> m["label"] = label }
                                    m
                                })
                            }
                        }
                        Email.CONTENT_ITEM_TYPE -> c.getString(3)?.let { if (it !in b.emails) b.emails.add(it) }
                    }
                }
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "no contacts permission")
        }
        return byId.values.map { b ->
            val m = mutableMapOf<String, Any?>(
                "id" to b.id, "name" to b.name, "phones" to b.phones, "emails" to b.emails, "starred" to b.starred,
            )
            if (withPhotos) b.photo?.let(::thumbnail)?.let { m["photo"] = it }
            m
        }
    }

    private class Builder(val id: Long, val name: String, val starred: Boolean, val photo: String?) {
        val phones = ArrayList<Map<String, Any?>>()
        val emails = ArrayList<String>()
    }

    private fun phoneType(t: Int) = when (t) {
        Phone.TYPE_MOBILE -> "mobile"
        Phone.TYPE_HOME -> "home"
        Phone.TYPE_WORK, Phone.TYPE_WORK_MOBILE -> "work"
        Phone.TYPE_MAIN -> "main"
        else -> "other"
    }

    private fun typeCode(t: String) = when (t) {
        "home" -> Phone.TYPE_HOME
        "work" -> Phone.TYPE_WORK
        "main" -> Phone.TYPE_MAIN
        "other" -> Phone.TYPE_OTHER
        else -> Phone.TYPE_MOBILE
    }

    /** Down-scaled JPEG (≤ 96 px), base64. */
    private fun thumbnail(uri: String): String? = try {
        cr.openInputStream(Uri.parse(uri))?.use { s ->
            val bmp = BitmapFactory.decodeStream(s) ?: return null
            val scale = 96f / maxOf(bmp.width, bmp.height)
            val small = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true) else bmp
            val out = ByteArrayOutputStream()
            small.compress(Bitmap.CompressFormat.JPEG, 70, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }
    } catch (t: Throwable) {
        null
    }

    /** Star / unstar a contact (Favourites, as in the Phone app). Returns rows changed or -1. */
    fun setStarred(contactId: Long, on: Boolean): Int = try {
        cr.update(ContactsContract.Contacts.CONTENT_URI, android.content.ContentValues().apply { put(ContactsContract.Contacts.STARRED, if (on) 1 else 0) },
            "${ContactsContract.Contacts._ID} = ?", arrayOf(contactId.toString()))
    } catch (t: Throwable) {
        Log.w(TAG, "star refused: ${t.message}"); -1
    }

    /** Inserts a device-local contact. Never modifies existing ones. Returns the new contact id, or -1. */
    fun add(name: String, phones: List<Map<String, Any?>>, emails: List<String>): Long {
        val ops = ArrayList<ContentProviderOperation>()
        ops.add(ContentProviderOperation.newInsert(RawContacts.CONTENT_URI)
            .withValue(RawContacts.ACCOUNT_TYPE, null).withValue(RawContacts.ACCOUNT_NAME, null).build())
        ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValueBackReference(Data.RAW_CONTACT_ID, 0)
            .withValue(Data.MIMETYPE, StructuredName.CONTENT_ITEM_TYPE).withValue(StructuredName.DISPLAY_NAME, name).build())
        for (p in phones) ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValueBackReference(Data.RAW_CONTACT_ID, 0)
            .withValue(Data.MIMETYPE, Phone.CONTENT_ITEM_TYPE).withValue(Phone.NUMBER, p["n"] as? String ?: "")
            .withValue(Phone.TYPE, typeCode(p["type"] as? String ?: "mobile")).build())
        for (e in emails) ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValueBackReference(Data.RAW_CONTACT_ID, 0)
            .withValue(Data.MIMETYPE, Email.CONTENT_ITEM_TYPE).withValue(Email.ADDRESS, e).withValue(Email.TYPE, Email.TYPE_HOME).build())
        val res = cr.applyBatch(ContactsContract.AUTHORITY, ops)
        val rawId = res[0].uri?.lastPathSegment?.toLongOrNull() ?: return -1
        cr.query(RawContacts.CONTENT_URI, arrayOf(RawContacts.CONTACT_ID), "${RawContacts._ID} = ?", arrayOf(rawId.toString()), null)?.use {
            if (it.moveToFirst()) return it.getLong(0)
        }
        return -1
    }

    /**
     * Edits an existing contact: sets its name and replaces its phone numbers and e-mail addresses.
     * A contact can be made of several raw contacts (phone, Google, WhatsApp…). Only the writable ones are
     * touched; the new numbers go into the first of them. Returns null on success, otherwise the reason.
     */
    fun update(contactId: Long, name: String, phones: List<Map<String, Any?>>, emails: List<String>): String? {
        if (contactId < 0 || name.isBlank()) return "missing contact or name"
        val raws = ArrayList<Long>()
        cr.query(RawContacts.CONTENT_URI, arrayOf(RawContacts._ID),
            "${RawContacts.CONTACT_ID} = ? AND ${RawContacts.DELETED} = 0 AND ${RawContacts.RAW_CONTACT_IS_READ_ONLY} = 0",
            arrayOf(contactId.toString()), RawContacts._ID)?.use { c -> while (c.moveToNext()) raws.add(c.getLong(0)) }
        if (raws.isEmpty()) return "this contact cannot be edited (read-only account)"
        val primary = raws.first()
        val inRaws = "${Data.RAW_CONTACT_ID} IN (${raws.joinToString(",")})"
        val ops = ArrayList<ContentProviderOperation>()
        // Name: replace the structured name of the primary raw contact (the provider re-splits DISPLAY_NAME).
        ops.add(ContentProviderOperation.newDelete(Data.CONTENT_URI)
            .withSelection("${Data.RAW_CONTACT_ID} = ? AND ${Data.MIMETYPE} = ?", arrayOf(primary.toString(), StructuredName.CONTENT_ITEM_TYPE)).build())
        ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValue(Data.RAW_CONTACT_ID, primary)
            .withValue(Data.MIMETYPE, StructuredName.CONTENT_ITEM_TYPE).withValue(StructuredName.DISPLAY_NAME, name).build())
        // Phones and e-mails: touch only what changed. A row that stays keeps its raw contact (Google, phone…),
        // its type and its custom label; a removed one is deleted where it lives; a new one goes into the primary.
        data class Row(val id: Long, val mime: String, val value: String, val type: Int)
        val existing = ArrayList<Row>()
        cr.query(Data.CONTENT_URI, arrayOf(Data._ID, Data.MIMETYPE, Data.DATA1, Data.DATA2), "$inRaws AND ${Data.MIMETYPE} IN (?, ?)",
            arrayOf(Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE), null)?.use { c ->
            while (c.moveToNext()) existing.add(Row(c.getLong(0), c.getString(1) ?: "", c.getString(2) ?: "", c.getInt(3)))
        }
        val keep = HashSet<Long>()
        for (p in phones) {
            val n = p["n"] as? String ?: continue
            val match = existing.firstOrNull { it.mime == Phone.CONTENT_ITEM_TYPE && it.id !in keep && numberKey(it.value) == numberKey(n) && numberKey(n).isNotEmpty() }
            if (match != null) {
                keep.add(match.id)
                // Same number: update the text if it was retyped, and the type only when the user changed it.
                val v = android.content.ContentValues()
                if (match.value != n) v.put(Phone.NUMBER, n)
                if (phoneType(match.type) != (p["type"] as? String ?: "mobile")) { v.put(Phone.TYPE, typeCode(p["type"] as? String ?: "mobile")); v.putNull(Phone.LABEL) }
                if (v.size() > 0) ops.add(ContentProviderOperation.newUpdate(Data.CONTENT_URI)
                    .withSelection("${Data._ID} = ?", arrayOf(match.id.toString())).withValues(v).build())
            } else {
                ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValue(Data.RAW_CONTACT_ID, primary)
                    .withValue(Data.MIMETYPE, Phone.CONTENT_ITEM_TYPE).withValue(Phone.NUMBER, n).withValue(Phone.TYPE, typeCode(p["type"] as? String ?: "mobile")).build())
            }
        }
        for (e in emails) {
            val match = existing.firstOrNull { it.mime == Email.CONTENT_ITEM_TYPE && it.id !in keep && it.value.equals(e, ignoreCase = true) }
            if (match != null) keep.add(match.id)
            else ops.add(ContentProviderOperation.newInsert(Data.CONTENT_URI).withValue(Data.RAW_CONTACT_ID, primary)
                .withValue(Data.MIMETYPE, Email.CONTENT_ITEM_TYPE).withValue(Email.ADDRESS, e).withValue(Email.TYPE, Email.TYPE_HOME).build())
        }
        // The same number or address kept in two accounts shows once on the iPhone: a copy whose value is still
        // wanted stays where it is (only values the user removed are deleted).
        val wantedPhones = phones.mapNotNull { numberKey(it["n"] as? String ?: "") }.filter { it.isNotEmpty() }.toSet()
        val wantedEmails = emails.map { it.lowercase() }.toSet()
        fun wanted(r: Row) = if (r.mime == Phone.CONTENT_ITEM_TYPE) numberKey(r.value) in wantedPhones else r.value.lowercase() in wantedEmails
        for (r in existing) if (r.id !in keep && !wanted(r)) ops.add(ContentProviderOperation.newDelete(Data.CONTENT_URI)
            .withSelection("${Data._ID} = ?", arrayOf(r.id.toString())).build())
        cr.applyBatch(ContactsContract.AUTHORITY, ops)
        return null
    }

    /** Name lookup for a number (used for call.state). */
    fun nameFor(number: String): String? = try {
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
        cr.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    } catch (t: Throwable) {
        null
    }

    companion object { const val TAG = "SimBridge" }
}

/** Call log, in the JSON shape of Dart's `CallEntry`. */
class CallLogRepo(private val ctx: Context, private val sims: SimRepo) {
    @android.annotation.SuppressLint("MissingPermission")
    fun since(since: Long, cap: Int = 1000): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val cols = arrayOf(CallLog.Calls._ID, CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME, CallLog.Calls.DATE,
            CallLog.Calls.DURATION, CallLog.Calls.TYPE, CallLog.Calls.PHONE_ACCOUNT_ID)
        val (sel, args, order) = if (since <= 0) Triple(null, null, "${CallLog.Calls._ID} DESC")
        else Triple("${CallLog.Calls._ID} > ?", arrayOf(since.toString()), "${CallLog.Calls._ID} ASC")
        try {
            val qa = android.os.Bundle().apply {
                sel?.let { putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, it) }
                args?.let { putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, it) }
                putString(android.content.ContentResolver.QUERY_ARG_SQL_SORT_ORDER, order)
                putInt(android.content.ContentResolver.QUERY_ARG_LIMIT, cap)
            }
            ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, cols, qa, null)?.use { c ->
                while (c.moveToNext()) {
                    val m = mutableMapOf<String, Any?>(
                        "id" to c.getLong(0), "num" to (c.getString(1) ?: ""), "date" to c.getLong(3),
                        "dur" to c.getInt(4), "type" to c.getInt(5),
                    )
                    c.getString(2)?.let { m["name"] = it }
                    sims.subForAccountId(c.getString(6))?.let { m["sub"] = it }
                    out.add(m)
                }
            }
        } catch (e: SecurityException) {
            Log.w(ContactsRepo.TAG, "no call log permission")
        }
        return if (since <= 0) out.reversed() else out
    }

    /** Every call-log id on the phone (for sync.ids). */
    fun allIds(): List<Long> = try {
        ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, arrayOf(CallLog.Calls._ID), null, null, "${CallLog.Calls._ID} ASC")
            ?.use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } } ?: emptyList()
    } catch (t: Throwable) { emptyList() }

    /** Deletes call-log rows (as the default phone app); all of them when [ids] is null. Returns rows deleted or -1. */
    fun delete(ids: List<Long>?): Int = try {
        if (ids == null) ctx.contentResolver.delete(CallLog.Calls.CONTENT_URI, null, null)
        else ids.chunked(200).sumOf { ch -> ctx.contentResolver.delete(CallLog.Calls.CONTENT_URI, "${CallLog.Calls._ID} IN (${ch.joinToString(",")})", null) }
    } catch (t: Throwable) {
        Log.w(ContactsRepo.TAG, "call log delete refused: ${t.message}")
        -1
    }
}
