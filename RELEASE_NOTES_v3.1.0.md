# UNIUN v3.1.0 — Release Notes

**October 11, 2026**

Gujarati and Japanese land, Shiv can now look at a photo you attach, chats open where you left off, and Ganas get a dashboard and a choice of what they know.

---

## What's New

### New languages — Gujarati and Japanese
Pick Gujarati or Japanese from the language picker. Hindi is also now complete.

### Ask Shiv about a photo
With a vision-capable model (Gemma 4 E2B or E4B) you can attach a picture to a Shiv chat message and ask about it directly.

### Gana dashboard
One screen showing totals, the Ganas that need attention, how each one has been doing, and the full reason behind a failed run.

### Ganas know what they need
Ganas can now use all of Brahma, a single Manas, or no knowledge at all. Choose "No knowledge" for a Gana that doesn't need your notes. Picking Brahma with a cloud model warns you that your notes are sent to that model.

### Chats open where you left off
Public groups, private groups, and DMs open at the first note you haven't read, under a "New notes" line. The jump-to-latest button shows how many are waiting.

### Easier to follow replies
A reply to a reply now counts as new, the note shows "New", and notes above it show "New reply inside" so you can follow the trail down.

### Unread counts in the drawer
Public and private groups now show an unread count badge in the drawer, just like DMs.

### Keep your AI models on logout
A new logout option lets you keep downloaded AI models for the next account, so you don't have to re-download them.

---

## Fixes
- The notification dot stayed on after reading a chat — notes are now marked read as they appear on screen.
- Logging out didn't fully reset the account — notes, DMs, media, AI choices, and sign-ins from the previous account are now cleared properly.
- Creating a Manas from a Gana said "Gana not found" even though the Manas was created, and lost what you had typed — your draft is kept now.
- The Manas check mark in the graph followed the wrong note after selecting another one.
- The app version in the privacy footer was stale ("v1.0.0-beta") — it now shows the installed version in every language.
- Gana cards overflowed on narrow screens and with large text.

---

## Under the Hood
- Notes are now embedded reliably — saved to a queue and processed one at a time, so closing the app, a crash, or a busy AI no longer loses them. A Shiv question always jumps ahead of the queue.
- Note search was missing many results past ~100 notes — the search index was upgraded and now finds them reliably.
- The note-search database runs in its own background thread, so saving and searching no longer makes scrolling stutter.
- A new CI pipeline checks Android, iOS, and Windows on every pull request.

---

## Download

| Platform | Link |
|----------|------|
| iOS (App Store) | [apps.apple.com/in/app/uniun/id6778077321](https://apps.apple.com/in/app/uniun/id6778077321) |
| Android (Play Store) | [play.google.com/store/apps/details?id=in.uniun.app](https://play.google.com/store/apps/details?id=in.uniun.app&hl=en_IN&pli=1) |
| Windows | Download `uniun-setup-v3.1.0.exe` from this release and run it to install |

---

## Full Changelog

See [CHANGELOG.md](CHANGELOG.md) for the complete history.
