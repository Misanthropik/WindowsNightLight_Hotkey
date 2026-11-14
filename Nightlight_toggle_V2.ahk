#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================================
; Night Light toggle for Windows 11 (Tested on 25h2) (AutoHotkey v2)
;
; Does what Windows does when you click the Quick Settings tile: edits the
; REG_BINARY "Data" value under CloudStore\...\bluelightreductionstate\Current
; and mirrors a counter delta into the sibling "Cloud" key.
;
;
; SAFETY NOTES
;   * Every byte the layout defines is validated (trailer = exactly four zero
;     bytes, flag = inner length + 1). Anything else is refused, changing
;     nothing. The input array is never modified; the new blob is built on a
;     clone, re-parsed, and must be valid, opposite-state, with the expected
;     counter and FILETIME before it is ever written.
;   * OVERFLOW FAILSAFE: AHK integers are signed 64-bit. Refuse if the parsed
;     counter is >= 2^63, if stored+2 would overflow, if the max-rule result
;     is not a positive integer, or if a counter is wider than 9 bytes. The
;     same guard applies to Cloud counter + delta. A wrapped value never
;     reaches a blob.
;   * ShellHost.exe, SystemSettings.exe and Explorer.EXE re-encode these values
;     within milliseconds, so success is judged by re-reading and re-parsing
;     (did the state flip?), never by byte comparison. The counter is stamped
;     by a COM provider in svchost, so seeding the blob cannot influence it.
;     No retries, no loops, no fighting the re-encode.
;
; HOW TO USE
;   1. Leave DRY_RUN := true first. On start the script runs a self-test; the
;      hotkey then shows what it WOULD write (Current and the Cloud delta).
;      CTRL + ALT + N is the default hotkey. Change at bottom of the script.
;   2. Set DRY_RUN := false for live use.
;   3. ENABLE_BACKUP: when true, a .reg backup of both keys is exported to
;      %TEMP% once per session (live mode only). When false, no backup is
;      made and no backup failure is reported.
;   4. ENABLE_LOG: when true, results are appended to nightlight_toggle.log
;      next to the script (live mode only). When false, nothing is logged.
;   5. FORCE_STATE: "" = flip, "on" / "off" = idempotent set.
; ============================================================================

DRY_RUN := true
ENABLE_LOG := true       ; append results to nightlight_toggle.log (live mode)
ENABLE_BACKUP := true    ; export a .reg backup to script directory once per session (live mode)
SHOW_TOAST := false
FORCE_STATE := ""        ; "" = flip, "on" / "off" = idempotent set
LOG_MAX := 200000        ; bytes; rotate to .old above this
DEBOUNCE_MS := 50        ; stamped only AFTER the whole operation finishes
MIRROR_WAIT_MS := 150    ; wait before touching Cloud

KEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate"
KEY_CLOUD := "HKCU\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Cloud\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate"
VAL := "Data"

MAXI := 0x7FFFFFFFFFFFFFFF          ; 2^63 - 1, the largest AHK integer
EPOCH_FT := 116444736000000000      ; FILETIME of 1970-01-01
SessionBackedUp := false

if DRY_RUN
    SelfTest()

; ---------------------------------------------------------------------------
; Byte / varint helpers (arrays are 1-based)
; ---------------------------------------------------------------------------
IsHex(s) {
    if Type(s) != "String" || s = ""
        return false
    return RegExMatch(s, "D)^([0-9A-Fa-f]{2})+$") ? true : false
}

HexToBytes(hex) {
    b := []
    Loop StrLen(hex) // 2
        b.Push(Integer("0x" SubStr(hex, A_Index * 2 - 1, 2)))
    return b
}

BytesToHex(b) {
    s := ""
    for v in b
        s .= Format("{:02X}", v)
    return s
}

GetB(b, i) {
    if i < 1 || i > b.Length
        throw Error("index out of range")
    return b[i]
}

; Value of a varint of exactly len bytes, or -1 if len is outside 1..9 or any
; part would push the value past 2^63-1.
ReadVarint(b, start, len) {
    if len < 1 || len > 9
        return -1
    v := 0
    Loop len {
        shift := 7 * (A_Index - 1)
        part := GetB(b, start + A_Index - 1) & 0x7F
        if part > (MAXI >> shift)
            return -1
        v |= part << shift
    }
    return v
}

; Writes v as a varint of exactly len bytes (padded). False if it does not
; fit; nothing is written in that case.
WriteVarint(b, start, len, v) {
    if len < 1 || len > 9 || v < 0 || start < 1 || start + len - 1 > b.Length
        return false
    if len < 9 && (v >> (7 * len)) != 0
        return false
    Loop len {
        part := v & 0x7F
        v >>= 7
        if A_Index < len
            part |= 0x80
        b[start + A_Index - 1] := part
    }
    return true
}

; Varint at natural (minimal) width, as an array.
EncodeVarint(v) {
    if v < 0
        throw Error("negative varint")
    out := []
    Loop {
        part := v & 0x7F
        v >>= 7
        if v {
            out.Push(part | 0x80)
        } else {
            out.Push(part)
            break
        }
    }
    return out
}

GetNowFileTime() {
    ft := 0
    DllCall("GetSystemTimeAsFileTime", "Int64*", &ft)
    return ft
}

UnixToFT(t) => t * 10000000 + 116444736000000000

; ---------------------------------------------------------------------------
; Current blob parsing and toggling
; ---------------------------------------------------------------------------
ParseBlob(b) {
    try {
        return ParseCore(b)
    } catch as e {
        return {ok: false, why: "layout not recognised (" e.Message ")"}
    }
}

ParseCore(b) {
    static HDR := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A]
    if Type(b) != "Array"
        return {ok: false, why: "value is not a byte array"}
    if b.Length < 37
        return {ok: false, why: "value is too short"}
    for i, v in HDR
        if GetB(b, i) != v
            return {ok: false, why: "unexpected header"}
    if GetB(b, 10) != 0x06
        return {ok: false, why: "byte 10 is not 0x06"}

    ; counter: ends at the first byte (from index 11) with the 0x80 bit clear
    ts0 := 11
    L := 0
    Loop {
        L++
        if L > 9
            return {ok: false, why: "counter is wider than 9 bytes (overflow)"}
        if !(GetB(b, ts0 + L - 1) & 0x80)
            break
    }
    counter := ReadVarint(b, ts0, L)
    if counter < 0
        return {ok: false, why: "counter is >= 2^63 (overflow)"}

    p := ts0 + L
    if GetB(b, p) != 0x2A || GetB(b, p + 1) != 0x2B || GetB(b, p + 2) != 0x0E
        return {ok: false, why: "unexpected bytes after the counter"}

    flagIdx := p + 3
    flag := GetB(b, flagIdx)
    if flag != 0x13 && flag != 0x15
        return {ok: false, why: "unknown state byte " Format("0x{:02X}", flag)}
    isOn := (flag = 0x15)

    q := flagIdx + 1
    for i, v in [0x43, 0x42, 0x01, 0x00]
        if GetB(b, q + i - 1) != v
            return {ok: false, why: "unexpected inner header"}
    c := q + 4

    insIdx := c
    if isOn {
        if GetB(b, c) != 0x10 || GetB(b, c + 1) != 0x00
            return {ok: false, why: "state says ON but the 10 00 marker is missing"}
        c += 2
    }

    for v in [0xD0, 0x0A, 0x02, 0xC6, 0x14] {
        if GetB(b, c) != v
            return {ok: false, why: "unexpected marker bytes before the time value"}
        c++
    }

    ft0 := c
    k := 0
    Loop {
        k++
        if k > 9
            return {ok: false, why: "time value is not 9 bytes"}
        if !(GetB(b, ft0 + k - 1) & 0x80)
            break
    }
    if k != 9
        return {ok: false, why: "time value is not 9 bytes"}
    ft1 := ft0 + 8
    ft := ReadVarint(b, ft0, 9)
    if ft < 0
        return {ok: false, why: "time value out of range"}

    c := ft1 + 1
    if b.Length - c + 1 != 4
        return {ok: false, why: "unexpected trailer length"}
    Loop 4 {
        if GetB(b, c + A_Index - 1) != 0
            return {ok: false, why: "unexpected trailer bytes"}
    }

    if (ft1 - q + 1) + 1 != flag
        return {ok: false, why: "state byte does not match the inner length"}

    return {ok: true, isOn: isOn, ts0: ts0, tsLen: L, counter: counter
        , flagIdx: flagIdx, insIdx: insIdx, ft0: ft0, ft: ft}
}

; Never modifies b. target: "" = flip, "on"/"off" = idempotent set.
; Returns {ok, bytes, wasOn, willBeOn, counter, oldCounter, delta,
;          counterBytes (width), rule, noop} or {ok:false, why}.
ToggleBytes(b, nowFT, target := "") {
    try {
        info := ParseBlob(b)
        if !info.ok
            return info

        target := StrLower(Trim(target))
        if target != "" && target != "on" && target != "off"
            return {ok: false, why: 'invalid target "' target '" (use "", "on" or "off")'}
        if target != "" && ((target = "on") = info.isOn)
            return {ok: true, noop: true, bytes: b, wasOn: info.isOn, willBeOn: info.isOn}

        if !IsInteger(nowFT) || nowFT <= 0
            return {ok: false, why: "invalid clock value"}

        stored := info.counter
        if stored > MAXI - 2
            return {ok: false, why: "counter overflow: stored+2 would exceed 2^63-1"}
        cand := stored + 2
        unixNow := (nowFT - EPOCH_FT) // 10000000
        if unixNow > cand {
            newC := unixNow
            rule := "now"
        } else {
            newC := cand
            rule := "stored+2"
        }
        if !IsInteger(newC) || newC < 1
            return {ok: false, why: "counter overflow: new counter is not a positive integer"}
        delta := newC - stored

        ; 1. re-encode the counter at natural width, then RE-PARSE
        enc := EncodeVarint(newC)
        nb := b.Clone()
        nb.RemoveAt(info.ts0, info.tsLen)
        nb.InsertAt(info.ts0, enc*)
        i2 := ParseBlob(nb)
        if !i2.ok || i2.counter != newC || i2.tsLen != enc.Length || i2.isOn != info.isOn
            return {ok: false, why: "internal check failed after re-encoding the counter"}

        ; 2. stamp FILETIME and flip the flag using the re-parsed indices
        if !WriteVarint(nb, i2.ft0, 9, nowFT)
            return {ok: false, why: "time value does not fit"}
        if i2.isOn {
            nb[i2.flagIdx] := 0x13
            nb.RemoveAt(i2.insIdx, 2)
        } else {
            nb[i2.flagIdx] := 0x15
            nb.InsertAt(i2.insIdx, 0x10, 0x00)
        }

        ; 3. re-parse: valid, opposite state, expected counter and FILETIME
        chk := ParseBlob(nb)
        if !chk.ok || chk.isOn = i2.isOn || chk.counter != newC || chk.ft != nowFT
            return {ok: false, why: "internal check of the new value failed"}

        return {ok: true, bytes: nb, wasOn: info.isOn, willBeOn: chk.isOn
            , counter: newC, oldCounter: stored, delta: delta
            , counterBytes: chk.tsLen, rule: rule, noop: false}
    } catch as e {
        return {ok: false, why: "layout not recognised (" e.Message ")"}
    }
}

; ---------------------------------------------------------------------------
; Cloud blob: 43 42 01 00 0A 00 26 | counter varint | 00
; ---------------------------------------------------------------------------
CloudParse(b) {
    static HDR := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26]
    if Type(b) != "Array" || b.Length < 10
        return {ok: false, why: "Cloud value is too short"}
    for i, v in HDR
        if b[i] != v
            return {ok: false, why: "unexpected Cloud header"}
    ts0 := 8
    k := 0
    Loop {
        k++
        if k > 9
            return {ok: false, why: "Cloud counter is wider than 9 bytes (overflow)"}
        if ts0 + k - 1 > b.Length
            return {ok: false, why: "Cloud counter is not terminated"}
        if !(b[ts0 + k - 1] & 0x80)
            break
    }
    if b.Length != ts0 + k || b[ts0 + k] != 0x00
        return {ok: false, why: "Cloud value must end with a single 00 after the counter"}
    counter := ReadVarint(b, ts0, k)
    if counter < 0
        return {ok: false, why: "Cloud counter is >= 2^63 (overflow)"}
    return {ok: true, ts0: ts0, tsLen: k, counter: counter}
}

; Pure. {ok, bytes, hex, counter, oldCounter} or {ok:false, outcome, why}.
PlanCloud(hex, delta) {
    try {
        if hex = ""
            return {ok: false, outcome: "absent", why: "Cloud value is absent"}
        if !IsHex(hex)
            return {ok: false, outcome: "malformed", why: "Cloud value is not binary hex data"}
        if !IsInteger(delta) || delta < 0
            return {ok: false, outcome: "malformed", why: "invalid delta"}
        b := HexToBytes(hex)
        p := CloudParse(b)
        if !p.ok
            return {ok: false, outcome: "malformed", why: p.why}
        if p.counter > MAXI - delta
            return {ok: false, outcome: "malformed", why: "Cloud counter + delta would overflow 2^63-1"}
        newC := p.counter + delta
        enc := EncodeVarint(newC)
        nb := b.Clone()
        nb.RemoveAt(p.ts0, p.tsLen)
        nb.InsertAt(p.ts0, enc*)
        chk := CloudParse(nb)
        if !chk.ok || chk.counter != newC
            return {ok: false, outcome: "malformed", why: "internal check of the new Cloud value failed"}
        return {ok: true, bytes: nb, hex: BytesToHex(nb), counter: newC, oldCounter: p.counter}
    } catch as e {
        return {ok: false, outcome: "malformed", why: "layout not recognised (" e.Message ")"}
    }
}

; Never throws. Outcomes: written / already / absent / malformed / mismatch.
MirrorCloud(snapHex, delta) {
    try {
        Sleep(MIRROR_WAIT_MS)
        r := ReadReg(KEY_CLOUD)
        cur := ""
        if r.ok
            cur := r.hex
        if cur !== snapHex
            return {outcome: "already"}          ; the shell got there first
        plan := PlanCloud(cur, delta)
        if !plan.ok
            return {outcome: plan.outcome}
        if !WriteReg(KEY_CLOUD, plan.hex)
            return {outcome: "mismatch"}
        v := ReadReg(KEY_CLOUD)
        if v.ok && IsHex(v.hex) {
            p := CloudParse(HexToBytes(v.hex))
            if p.ok && p.counter >= plan.counter   ; shell may already have re-encoded it
                return {outcome: "written"}
        }
        return {outcome: "mismatch"}
    } catch {
        return {outcome: "mismatch"}
    }
}

; ---------------------------------------------------------------------------
; Registry I/O
; ---------------------------------------------------------------------------
ReadReg(sub) {
    try {
        v := RegRead(sub, VAL)
    } catch {
        return {ok: false, hex: ""}
    }
    if Type(v) = "Buffer" {
        s := ""
        Loop v.Size
            s .= Format("{:02X}", NumGet(v, A_Index - 1, "UChar"))
        return {ok: true, hex: s}
    }
    if Type(v) = "String"
        return {ok: true, hex: StrUpper(Trim(v))}
    return {ok: true, hex: ""}               ; DWORD etc.: not binary, caller refuses
}

WriteReg(sub, hex) {
    try {
        RegWrite(hex, "REG_BINARY", sub, VAL)
    } catch {
        return false
    }
    return true
}

; One .reg stanza; hex: with commas and "\" continuation every 24 bytes.
RegSection(sub, hex) {
    full := sub
    if SubStr(sub, 1, 5) = "HKCU\"
        full := "HKEY_CURRENT_USER\" SubStr(sub, 6)
    h := StrLower(hex)
    n := StrLen(h) // 2
    s := '"' VAL '"=hex:'
    Loop n {
        s .= SubStr(h, A_Index * 2 - 1, 2)
        if A_Index < n
            s .= (Mod(A_Index, 24) = 0) ? ",\`r`n  " : ","
    }
    return "[" full "]`r`n" s "`r`n`r`n"
}

; Writes the .reg backup. Returns true on success. When ENABLE_BACKUP is false
; there is nothing to do, which is not a failure, so it also returns true.
ExportReg(curHex, cloudHex) {
    if !ENABLE_BACKUP
        return true
    try {
        txt := "Windows Registry Editor Version 5.00`r`n`r`n" RegSection(KEY, curHex)
        if IsHex(cloudHex)
            txt .= RegSection(KEY_CLOUD, cloudHex)
        f := FileOpen(A_Temp "\nightlight_backup_" A_Now ".reg", "w", "UTF-16")
        f.Write(txt)
        f.Close()
        return true
    } catch {
        return false
    }
}

; No-op in dry run and when ENABLE_LOG is false.
AppendLog(result, oldHex, newHex, mirror) {
    if DRY_RUN || !ENABLE_LOG
        return
    try {
        path := A_ScriptDir "\nightlight_toggle.log"
        if FileExist(path) && FileGetSize(path) > LOG_MAX
            FileMove(path, path ".old", true)
        stamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(stamp " | " result " | old=" oldHex " | new=" newHex " | mirror=" mirror "`n", path)
    } catch {
    }
}

ShowTip(text) {
    if !SHOW_TOAST
        return
    ToolTip(text)
    SetTimer(HideTip, -900)
}

HideTip() {
    if !SHOW_TOAST
        return
    ToolTip()
}

; ---------------------------------------------------------------------------
; The toggle itself
; ---------------------------------------------------------------------------
ToggleNightLight() {
    static busy := false
    static last := -1000
    if busy || (A_TickCount - last < DEBOUNCE_MS)
        return
    busy := true
    try {
        DoToggle()
    } finally {
        busy := false
        last := A_TickCount            ; stamped only after the whole operation
    }
}

Refuse(why, curHex, title, extra := "") {
    msg := "Not changing anything: " why
    if extra != ""
        msg .= "`n`n" extra
    if curHex != ""
        msg .= "`n`nCurrent value:`n" curHex
    MsgBox(msg, title, 0x10)
    AppendLog("REFUSED: " why, curHex, "", "none")
}

DoToggle() {
    global SessionBackedUp
    title := "Night Light toggle"

    cur := ReadReg(KEY)
    if !cur.ok {
        Refuse("could not read the Night Light value", "", title
            , "If you just deleted the key, switch Night Light once from Quick Settings (Win+A) so Windows recreates it.")
        return
    }
    curHex := cur.hex
    if !IsHex(curHex) {
        Refuse("value is not REG_BINARY data", curHex, title)
        return
    }

    cloud := ReadReg(KEY_CLOUD)
    cloudSnap := ""
    if cloud.ok
        cloudSnap := cloud.hex

    target := StrLower(Trim(FORCE_STATE))
    if target != "" && target != "on" && target != "off" {
        Refuse('FORCE_STATE must be "", "on" or "off"', curHex, title)
        return
    }

    nowFT := GetNowFileTime()                 ; the ONE clock read
    r := ToggleBytes(HexToBytes(curHex), nowFT, target)
    if !r.ok {
        Refuse(r.why, curHex, title)
        return
    }

    if r.noop {
        state := r.wasOn ? "on" : "off"
        if DRY_RUN {
            MsgBox("DRY RUN - Night Light is already " state ". Nothing would be written.", title)
            return
        }
        ShowTip("Night Light already " state)
        AppendLog("NOOP: already " state, curHex, curHex, "none")
        return
    }

    newHex := BytesToHex(r.bytes)
    plan := PlanCloud(cloudSnap, r.delta)

    if DRY_RUN {
        was := r.wasOn ? "ON" : "OFF"
        curLen := StrLen(curHex) // 2
        newLen := StrLen(newHex) // 2
        msg := "DRY RUN - nothing was written.`n`nNight Light is currently " was ".`n"
        msg .= "Counter " r.oldCounter " -> " r.counter " (" r.rule ", delta " r.delta ", width " r.counterBytes ")"
        msg .= "`n`nCurrent (" curLen " bytes):`n" curHex
        msg .= "`n`nWould write (" newLen " bytes):`n" newHex
        if plan.ok {
            cLen := StrLen(plan.hex) // 2
            msg .= "`n`nCloud delta +" r.delta " (counter " plan.oldCounter " -> " plan.counter ", " cLen " bytes):`n" plan.hex
        } else {
            msg .= "`n`nCloud: nothing would be written (" plan.outcome ": " plan.why ")"
        }
        MsgBox(msg, title)
        return
    }

    ; ---- live ----
    backupNote := ""
    if ENABLE_BACKUP && !SessionBackedUp {
        if ExportReg(curHex, cloudSnap)
            SessionBackedUp := true
        else
            backupNote := " [backup .reg export failed]"
    }

    if !WriteReg(KEY, newHex) {
        AppendLog("FAILED: RegWrite error" backupNote, curHex, newHex, "none")
        MsgBox("Write failed (RegWrite error). Nothing was changed.", title, 0x10)
        return
    }

    ; verify by re-reading and re-parsing: did the state flip?
    flipped := false
    chkR := ReadReg(KEY)
    if chkR.ok && IsHex(chkR.hex) {
        pp := ParseBlob(HexToBytes(chkR.hex))
        flipped := pp.ok && (pp.isOn = r.willBeOn)
    }
    if !flipped {
        ShowTip("Night Light: state did not flip")
        AppendLog("UNVERIFIED: state did not flip" backupNote, curHex, newHex, "skipped")
        return                                ; never retry, never fight the re-encode
    }

    nowState := r.willBeOn ? "on" : "off"
    ShowTip("Night Light " nowState)

    m := MirrorCloud(cloudSnap, r.delta)

    dir := r.wasOn ? "ON->OFF" : "OFF->ON"
    res := "OK " dir " counter " r.oldCounter "->" r.counter " (" r.rule ")" backupNote
    AppendLog(res, curHex, newHex, m.outcome)
}

; ---------------------------------------------------------------------------
; Self-test: runs the same code on synthetic and captured blobs.
; Touches nothing in the registry.
; ---------------------------------------------------------------------------
Check(results, name, cond) {
    results.Push([name, cond ? true : false])
}

; Parse of a result's bytes (or a failed parse if the result was refused).
PB(r) {
    if r.ok
        return ParseBlob(r.bytes)
    return {ok: false, why: "no bytes"}
}

; Bytes of a result, or an empty array when refused.
RB(r) {
    if r.ok
        return r.bytes
    return []
}

; "" when r holds exactly the expected bytes, otherwise a description.
Diff(r, expected) {
    if !r.ok
        return "refused: " r.why
    got := r.bytes
    if got.Length != expected.Length
        return "length " got.Length " != " expected.Length
    for i, v in got
        if v != expected[i]
            return Format("byte {} is {:02X}, expected {:02X}", i, v, expected[i])
    return ""
}

; Synthetic Current blob with a PADDED counter of the given width.
BuildBlob(counter, width, isOn, ft) {
    b := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06]
    cb := []
    Loop width
        cb.Push(0)
    WriteVarint(cb, 1, width, counter)
    for v in cb
        b.Push(v)
    flag := isOn ? 0x15 : 0x13
    for v in [0x2A, 0x2B, 0x0E, flag, 0x43, 0x42, 0x01, 0x00]
        b.Push(v)
    if isOn
        b.Push(0x10, 0x00)
    for v in [0xD0, 0x0A, 0x02, 0xC6, 0x14]
        b.Push(v)
    fb := []
    Loop 9
        fb.Push(0)
    WriteVarint(fb, 1, 9, ft)
    for v in fb
        b.Push(v)
    Loop 4
        b.Push(0)
    return b
}

BuildCloud(counter, width) {
    b := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26]
    cb := []
    Loop width
        cb.Push(0)
    WriteVarint(cb, 1, width, counter)
    for v in cb
        b.Push(v)
    b.Push(0x00)
    return b
}

SelfTest() {
    results := []
    try {
        t1 := UnixToFT(1794000000)
        t2 := UnixToFT(1794000100)
        t3 := UnixToFT(1794000200)

        on1 := HexToBytes("434201000A0201002A069D818080EB2A2A2B0E15434201001000D00A02C614F59ADBF99691DCEE0100000000")
        off := HexToBytes("434201000A0201002A069F818080EB2A2A2B0E1343420100D00A02C614AC97C79C9991DCEE0100000000")
        on2 := HexToBytes("434201000A0201002A06A1818080EB2A2A2B0E15434201001000D00A02C614F7F1E8EC9991DCEE0100000000")

        ; --- helpers sanity ---
        Check(results, "IsHex accepts even-length hex", IsHex("0aFf"))
        Check(results, "IsHex rejects empty / odd / non-hex", !IsHex("") && !IsHex("ABC") && !IsHex("GG"))
        tmp := EncodeVarint(300)
        Check(results, "EncodeVarint(300) = AC 02", tmp.Length = 2 && tmp[1] = 0xAC && tmp[2] = 0x02)
        Check(results, "ReadVarint rejects width 0 and 10", ReadVarint([1], 1, 0) = -1 && ReadVarint([1,1,1,1,1,1,1,1,1,1], 1, 10) = -1)

        ; --- 1. captured blobs, byte-for-byte ---
        Check(results, "captured blobs all parse", ParseBlob(on1).ok && ParseBlob(off).ok && ParseBlob(on2).ok)
        r := ToggleBytes(on1, ParseBlob(off).ft)
        Check(results, "captured ON -> OFF reproduces Windows' own OFF blob", Diff(r, off) = "")
        r := ToggleBytes(off, ParseBlob(on2).ft)
        Check(results, "captured OFF -> ON reproduces Windows' own ON blob", Diff(r, on2) = "")

        ; --- 2. refusals ---
        bad := off.Clone()
        bad[ParseBlob(off).flagIdx] := 0x00
        Check(results, "unknown flag is refused", !ToggleBytes(bad, t1).ok)
        bad := on1.Clone()
        bad.Pop()
        Check(results, "truncated blob is refused", !ToggleBytes(bad, t1).ok)
        bad := off.Clone()
        bad.Push(0x00)
        Check(results, "blob with an extra byte is refused", !ToggleBytes(bad, t1).ok)
        bad := on1.Clone()
        bad[ParseBlob(on1).insIdx] := 0x11
        Check(results, "ON blob without its 10 00 marker is refused", !ToggleBytes(bad, t1).ok)
        bad := off.Clone()
        bad[10] := 0x05
        Check(results, "byte 10 not 0x06 is refused", !ToggleBytes(bad, t1).ok)

        ; --- 3. 5-byte counter ---
        cnt5 := 5000000000
        off5 := BuildBlob(cnt5, 5, false, UnixToFT(1700000000))
        Check(results, "5-byte OFF blob is 41 bytes", off5.Length = 41 && ParseBlob(off5).ok)
        r := ToggleBytes(off5, t1)
        p := PB(r)
        Check(results, "5-byte OFF->ON: 43 bytes", r.ok && r.bytes.Length = 43)
        Check(results, "5-byte OFF->ON: counter+2, width 5, rule stored+2, delta 2"
            , r.ok && r.counter = cnt5 + 2 && r.counterBytes = 5 && r.rule = "stored+2" && r.delta = 2 && p.counter = cnt5 + 2 && p.tsLen = 5)
        Check(results, "5-byte OFF->ON: FILETIME stamped, flag 0x15", p.ok && p.ft = t1 && r.bytes[p.flagIdx] = 0x15)
        r2 := ToggleBytes(RB(r), t2)
        p2 := PB(r2)
        Check(results, "5-byte ON->OFF back: 41 bytes", r2.ok && r2.bytes.Length = 41)
        Check(results, "5-byte ON->OFF back: counter+4, flag 0x13, FILETIME stamped"
            , r2.ok && r2.counter = cnt5 + 4 && p2.ok && p2.counter = cnt5 + 4 && r2.bytes[p2.flagIdx] = 0x13 && p2.ft = t2)

        ; --- 4. 6-byte counter ---
        cnt6 := 40000000000
        on6 := BuildBlob(cnt6, 6, true, UnixToFT(1700000000))
        Check(results, "6-byte ON blob is 44 bytes", on6.Length = 44 && ParseBlob(on6).ok)
        r := ToggleBytes(on6, t1)
        p := PB(r)
        Check(results, "6-byte ON->OFF: 42 bytes, counter+2, flag 0x13"
            , r.ok && r.bytes.Length = 42 && r.counter = cnt6 + 2 && p.ok && r.bytes[p.flagIdx] = 0x13)
        r2 := ToggleBytes(RB(r), t2)
        p2 := PB(r2)
        Check(results, "6-byte back to ON: 44 bytes, counter+4, flag 0x15"
            , r2.ok && r2.bytes.Length = 44 && r2.counter = cnt6 + 4 && p2.ok && r2.bytes[p2.flagIdx] = 0x15)

        ; --- 5. UnixNow branch ---
        off2 := BuildBlob(1000, 2, false, UnixToFT(1700000000))
        r := ToggleBytes(off2, t2)
        p := PB(r)
        Check(results, "width 2 -> 43 bytes", off2.Length = 38 && r.ok && r.bytes.Length = 43)
        Check(results, "width 2 -> counter = 1794000100, rule now, width 5, flagIdx 19"
            , r.ok && r.counter = 1794000100 && r.rule = "now" && r.counterBytes = 5 && p.ok && p.counter = 1794000100 && p.flagIdx = 19)
        Check(results, "width 2 -> delta = 1794000100 - 1000", r.ok && r.delta = 1794000100 - 1000)

        ; --- 6. width shrink ---
        pad6 := BuildBlob(1000000000, 6, true, UnixToFT(1700000000))
        Check(results, "padded 6-byte counter parses with width 6", pad6.Length = 44 && ParseBlob(pad6).ok && ParseBlob(pad6).tsLen = 6)
        r := ToggleBytes(pad6, t1)
        p := PB(r)
        Check(results, "width shrink: 41 bytes, width 5, flagIdx 19, flag 0x13"
            , r.ok && r.bytes.Length = 41 && p.ok && p.tsLen = 5 && p.flagIdx = 19 && r.bytes[p.flagIdx] = 0x13)

        ; --- 7. idempotence ---
        r := ToggleBytes(off5, t1, "off")
        Check(results, "target off on an OFF blob is a noop with identical bytes"
            , r.ok && r.noop && BytesToHex(r.bytes) == BytesToHex(off5))
        r := ToggleBytes(off5, t1, "on")
        Check(results, "target on on an OFF blob toggles", r.ok && !r.noop && r.willBeOn && r.bytes.Length = 43)
        r := ToggleBytes(on6, t1, "on")
        Check(results, "target on on an ON blob is a noop", r.ok && r.noop)

        ; --- 8. overflow ---
        big := BuildBlob(MAXI - 1, 9, false, UnixToFT(1700000000))
        before := BytesToHex(big)
        Check(results, "2^63-2 blob parses", ParseBlob(big).ok && ParseBlob(big).counter = MAXI - 1)
        r := ToggleBytes(big, t1)
        Check(results, "2^63-2 is refused and names the overflow", !r.ok && InStr(r.why, "overflow") > 0)
        Check(results, "input array unchanged after refusal", BytesToHex(big) == before)
        big := BuildBlob(MAXI, 9, false, UnixToFT(1700000000))
        r := ToggleBytes(big, t1)
        Check(results, "2^63-1 is refused and names the overflow", !r.ok && InStr(r.why, "overflow") > 0)
        ten := BuildBlob(1 << 40, 9, false, UnixToFT(1700000000))
        ten.InsertAt(11, 0x80)
        r := ToggleBytes(ten, t1)
        Check(results, "10-byte counter is refused and names the overflow", !r.ok && InStr(r.why, "overflow") > 0)

        ; --- 9. Cloud ---
        cl := BuildCloud(cnt5, 5)
        cp := CloudParse(cl)
        Check(results, "valid 13-byte Cloud value parses", cl.Length = 13 && cp.ok && cp.counter = cnt5 && cp.tsLen = 5)
        pl := PlanCloud(BytesToHex(cl), 2)
        Check(results, "Cloud delta +2 keeps 13 bytes ending 00"
            , pl.ok && pl.bytes.Length = 13 && pl.bytes[13] = 0 && pl.counter = cnt5 + 2 && pl.oldCounter = cnt5)
        x := cl.Clone()
        x[13] := 0x01
        Check(results, "Cloud not ending 00 is refused", !CloudParse(x).ok)
        x := cl.Clone()
        x.Push(0x00)
        Check(results, "Cloud with an extra byte is refused", !CloudParse(x).ok)
        x := cl.Clone()
        x[5] := 0x0B
        Check(results, "Cloud with a wrong header is refused", !CloudParse(x).ok)
        Check(results, "Cloud too short is refused", !CloudParse([0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26, 0x01, 0x00]).ok)
        x := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26, 0x80, 0x80, 0x80]
        Check(results, "Cloud with an unterminated varint is refused", !CloudParse(x).ok)
        Check(results, "PlanCloud on an absent value -> absent", PlanCloud("", 2).outcome = "absent")
        Check(results, "PlanCloud on non-hex -> malformed", PlanCloud("ZZ", 2).outcome = "malformed")
        Check(results, "PlanCloud on a bad layout -> malformed", PlanCloud(BytesToHex(x), 2).outcome = "malformed")
        bigc := BuildCloud(MAXI - 1, 9)
        pl := PlanCloud(BytesToHex(bigc), 2)
        Check(results, "Cloud counter + delta reaching 2^63 is refused", !pl.ok && InStr(pl.why, "overflow") > 0)
    } catch as e {
        Check(results, "self-test crashed: " e.Message, false)
    }

    ; --- 10. report ---
    passed := 0
    fails := ""
    for item in results {
        if item[2]
            passed++
        else
            fails .= "FAIL  " item[1] "`n"
    }
    total := results.Length
    failed := total - passed
    msg := "Self-test: " passed "/" total " passed, " failed " failed."
    if fails != ""
        msg .= "`n`n" fails
    ok := (passed = total && total > 0)
	; Add the reminder when all tests pass successfully
    if (ok)
        msg .= "`n`nIf all passed, manually set DRY_RUN := false"
    MsgBox(msg, "Night Light toggle", ok ? 0x40 : 0x10)
}

; ---------------------------------------------------------------------------
; Hotkey (keep at the bottom). KeyWait stops a held key from auto-repeating.
; ---------------------------------------------------------------------------
^!n:: {
    ToggleNightLight()
    KeyWait("n")
}