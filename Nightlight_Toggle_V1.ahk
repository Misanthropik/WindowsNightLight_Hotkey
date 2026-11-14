#Requires AutoHotkey v1.1.33+
#SingleInstance Force

; ============================================================================
; Night Light toggle for Windows 11 (Tested on 25h2) (AutoHotkey v1.1)
;
; Does what Windows does when you click the Quick Settings tile: edits the
; "Data" value under CloudStore\...\bluelightreductionstate (Current key) and
; mirrors the counter into the matching Cloud key.
;
; SAFETY NOTES
;   * The script only writes when the blob matches the layout exactly and
;     refuses (changing nothing) otherwise.
;   * AHK v1 integers are signed 64-bit. Any counter that would reach 2^63 is
;     refused with an "overflow" message; a wrapped value never reaches a blob.
;   * Shell processes re-encode these values within milliseconds, so success is
;     checked by re-reading and re-parsing (did the state flip?), not by exact
;     bytes. The script never retries or fights the shell.
;
; HOW TO USE
;   1. Leave DRY_RUN := true first. On start the script runs a self-test.
;      Press the hotkey to see what it WOULD write (Current and Cloud).
;      CTRL + ALT + N is the default hotkey. Change at bottom of the script.
;   2. Set DRY_RUN := false. Unless ENABLE_BACKUP is false, a .reg backup is
;      saved next to the script before the first write of each session. Unless
;      ENABLE_LOG is false, every live toggle is appended to
;      nightlight_log.txt (size-capped).
;   3. ENABLE_BACKUP: when true, a .reg backup of both keys is exported to
;      %TEMP% once per session (live mode only). When false, no backup is
;      made and no backup failure is reported.
;   4. ENABLE_LOG: when true, results are appended to nightlight_toggle.log
;      next to the script (live mode only). When false, nothing is logged.
;   5. FORCE_STATE: "" = flip, "on" / "off" = idempotent set.
; ============================================================================

DRY_RUN := true
ENABLE_LOG := true       ; append every live toggle to nightlight_log.txt
ENABLE_BACKUP := true    ; write a .reg backup before the first write of each session
SHOW_TOAST := false      ; Display Tooltip showing Night Light ON/OFF state at cursor position
FORCE_STATE := ""        ; "" = toggle, "on" / "off" = idempotent set (no-op if already there)
LOG_MAX := 200000        ; bytes; the log is rotated to .old above this
DEBOUNCE_MS := 50        ; stamped only AFTER the whole operation finishes, blocks repeat press
MIRROR_WAIT_MS := 150    ; wait before touching Cloud, so the shell can update it first

; v1 RegRead/RegWrite take the root key separately from the subkey
KEY_SUB := "Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate"
KEY_CLOUD := "Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Cloud\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate"
VAL := "Data"

if (DRY_RUN)
    SelfTest()

; The auto-execute section ends at the first hotkey below.
; Function definitions in between do not interfere with it.

; ---------------------------------------------------------------------------
; Byte helpers (arrays are 1-based)
; ---------------------------------------------------------------------------
IsHex(s) {
    return (s != "" && RegExMatch(s, "^([0-9A-Fa-f]{2})+$")) ? 1 : 0
}

HexToBytes(hex) {
    b := []
    digits := "0123456789ABCDEF"
    n := StrLen(hex) // 2
    Loop, %n%
    {
        hi := InStr(digits, SubStr(hex, A_Index * 2 - 1, 1)) - 1
        lo := InStr(digits, SubStr(hex, A_Index * 2, 1)) - 1
        b.Push(hi * 16 + lo)
    }
    return b
}

BytesToHex(b) {
    s := ""
    for _, v in b
        s .= Format("{:02X}", v)
    return s
}

; Bounds-checked read. v1 silently returns blank on a bad index, so we throw
; to keep the "refuse if the layout is wrong" behaviour. Use it for every read.
GetB(b, i) {
    if (i < 1 || i > b.Length())
        throw Exception("index " i " out of range")
    return b[i]
}

; Returns the value, or -1 if it would not fit a signed 64-bit integer.
; 9 bytes carry 63 bits, which always fits; 10+ bytes can wrap, so they are
; refused here (and every shift is range-checked before it is applied).
ReadVarint(b, start, len) {
    if (len < 1 || len > 9)
        return -1
    v := 0
    Loop, %len%
    {
        s := 7 * (A_Index - 1)
        part := GetB(b, start + A_Index - 1) & 0x7F
        if (part > (9223372036854775807 >> s))
            return -1
        v |= part << s
    }
    return v
}

; Writes v as a varint of exactly len bytes (padded if needed).
; Returns false if v does not fit.
WriteVarint(b, start, len, v) {
    Loop, %len%
    {
        bt := v & 0x7F
        v >>= 7
        if (A_Index < len)
            bt |= 0x80
        b[start + A_Index - 1] := bt
    }
    return (v = 0)
}

; Natural-width (minimum bytes) varint of a positive integer, as an array.
EncodeVarint(v) {
    out := []
    Loop
    {
        bt := v & 0x7F
        v >>= 7
        if (v > 0)
        {
            out.Push(bt | 0x80)
        }
        else
        {
            out.Push(bt)
            break
        }
    }
    return out
}

; AHK v1 integers are signed 64-bit, so the FILETIME (~1.3e17) is exact.
GetNowFileTime() {
    ft := 0
    DllCall("GetSystemTimeAsFileTime", "Int64*", ft)
    return ft
}

UnixToFT(t) {
    return t * 10000000 + 116444736000000000
}

; ---------------------------------------------------------------------------
; Current blob parsing and toggling
; ---------------------------------------------------------------------------
ParseBlob(b) {
    try
    {
        return ParseBlobCore(b)
    }
    catch e
    {
        return {ok: false, why: "layout not recognised (" . e.Message . ")"}
    }
}

ParseBlobCore(b) {
    HDR := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06]
    if (b.Length() < 30)
        return {ok: false, why: "value is too short"}
    for i, v in HDR
    {
        if (GetB(b, i) != v)
            return {ok: false, why: "unexpected header"}
    }

    ; Counter: starts at 11, ends at the first byte with the 0x80 bit clear.
    ts0 := 11
    L := 0
    Loop
    {
        bt := GetB(b, ts0 + L)
        L++
        if !(bt & 0x80)
            break
        if (L >= 9)
            return {ok: false, why: "counter is wider than 9 bytes (integer overflow: value would reach 2^63)"}
    }
    ts1 := ts0 + L - 1
    counter := ReadVarint(b, ts0, L)
    if (counter < 0)
        return {ok: false, why: "counter overflow: does not fit a signed 64-bit integer"}

    p := ts1 + 1
    if (GetB(b, p) != 0x2A || GetB(b, p + 1) != 0x2B || GetB(b, p + 2) != 0x0E)
        return {ok: false, why: "unexpected bytes after the counter"}

    flagIdx := p + 3
    flag := GetB(b, flagIdx)
    if (flag != 0x13 && flag != 0x15)
        return {ok: false, why: "unknown state byte " . Format("0x{:02X}", flag)}
    isOn := (flag = 0x15)

    q := flagIdx + 1
    c := q
    if (GetB(b, c) != 0x43 || GetB(b, c + 1) != 0x42 || GetB(b, c + 2) != 0x01 || GetB(b, c + 3) != 0x00)
        return {ok: false, why: "unexpected inner header"}
    c += 4

    insIdx := c
    if (isOn)
    {
        if (GetB(b, c) != 0x10 || GetB(b, c + 1) != 0x00)
            return {ok: false, why: "state says ON but the 10 00 marker is missing"}
        c += 2
    }

    markers := [0xD0, 0x0A, 0x02, 0xC6, 0x14]
    for _, v in markers
    {
        if (GetB(b, c) != v)
            return {ok: false, why: "unexpected marker bytes before the time value"}
        c++
    }

    ft0 := c
    Loop, 9
    {
        bt := GetB(b, ft0 + A_Index - 1)
        isLast := (A_Index = 9)
        hasMore := ((bt & 0x80) != 0)
        if (isLast = hasMore)
            return {ok: false, why: "time value is not a 9-byte varint"}
    }
    ft1 := ft0 + 8
    ft := ReadVarint(b, ft0, 9)
    if (ft < 0)
        return {ok: false, why: "time value overflow"}
    c := ft1 + 1

    if (b.Length() - c + 1 != 4)
        return {ok: false, why: "unexpected trailer length"}
    Loop, 4
    {
        if (GetB(b, c + A_Index - 1) != 0)
            return {ok: false, why: "unexpected trailer bytes"}
    }

    if (((ft1 - q + 1) + 1) != flag)
        return {ok: false, why: "state byte does not match the inner length"}

    return {ok: true, isOn: isOn, ts0: ts0, tsLen: L, counter: counter, flagIdx: flagIdx, insIdx: insIdx, ft0: ft0, ft: ft}
}

; target: "" = flip, 1 = want ON, 0 = want OFF.
; Returns {ok, bytes, wasOn, willBeOn, counter, oldCounter, delta, counterBytes,
; rule, noop} or {ok: false, why}. Never modifies b.
ToggleBytes(b, nowFT, target := "") {
    try
    {
        info := ParseBlob(b)
        if !info.ok
            return info

        want := (target = "") ? !info.isOn : (target ? 1 : 0)
        if (want = info.isOn)
            return {ok: true, noop: true, bytes: b, wasOn: info.isOn, willBeOn: want}

        ; One clock read: UnixNow comes from the same FILETIME that is stamped.
        if (nowFT < 116444736000000000)
            return {ok: false, why: "system clock gives an invalid FILETIME"}
        unixNow := (nowFT - 116444736000000000) // 10000000
        if (unixNow < 1)
            return {ok: false, why: "system clock gives a non-positive Unix time"}

        stored := info.counter
        if (stored < 0 || stored > 9223372036854775805)
            return {ok: false, why: "counter overflow: stored counter " . stored . " + 2 would reach 2^63 (signed 64-bit limit); nothing written"}

        bumped := stored + 2
        newC := (unixNow > bumped) ? unixNow : bumped
        if (newC < 1 || newC < bumped)
            return {ok: false, why: "counter overflow: new counter is not a positive integer; nothing written"}
        delta := newC - stored

        ; Re-encode the counter at natural width, then RE-PARSE: a width change
        ; moves the flag index and the marker insertion point.
        enc := EncodeVarint(newC)
        nb := b.Clone()
        nb.RemoveAt(info.ts0, info.tsLen)
        nb.InsertAt(info.ts0, enc*)
        mid := ParseBlob(nb)
        if (!mid.ok || mid.counter != newC || mid.isOn != info.isOn)
            return {ok: false, why: "internal check failed after counter re-encode: " . mid.why}

        if !WriteVarint(nb, mid.ft0, 9, nowFT)
            return {ok: false, why: "time value does not fit"}

        if (mid.isOn)
        {
            nb[mid.flagIdx] := 0x13
            nb.RemoveAt(mid.insIdx, 2)
        }
        else
        {
            nb[mid.flagIdx] := 0x15
            nb.InsertAt(mid.insIdx, 0x10, 0x00)
        }

        chk := ParseBlob(nb)    ; must itself be a valid, opposite-state blob
        if (!chk.ok || chk.isOn = info.isOn || chk.counter != newC || chk.ft != nowFT)
            return {ok: false, why: "internal check of the new value failed: " . chk.why}

        return {ok: true, bytes: nb, wasOn: info.isOn, willBeOn: want, counter: newC, oldCounter: stored, delta: delta, counterBytes: enc, rule: ((newC = bumped) ? "stored+2" : "now")}
    }
    catch e
    {
        return {ok: false, why: "layout not recognised (" . e.Message . ")"}
    }
}

; ---------------------------------------------------------------------------
; Cloud delta: 43 42 01 00 0A 00 26 | <counter varint> | 00
; ---------------------------------------------------------------------------
CloudParse(b) {
    try
    {
        n := b.Length()
        if (n < 10)
            return {ok: false, why: "Cloud value is too short"}
        hdr := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26]
        for i, v in hdr
        {
            if (GetB(b, i) != v)
                return {ok: false, why: "Cloud header is unexpected"}
        }
        L := 0
        Loop
        {
            bt := GetB(b, 8 + L)
            L++
            if !(bt & 0x80)
                break
            if (L >= 9)
                return {ok: false, why: "Cloud counter is wider than 9 bytes (overflow)"}
        }
        if (8 + L != n)
            return {ok: false, why: "Cloud value has an unexpected length after the counter"}
        if (GetB(b, n) != 0)
            return {ok: false, why: "Cloud value does not end in 00"}
        counter := ReadVarint(b, 8, L)
        if (counter < 0)
            return {ok: false, why: "Cloud counter overflow"}
        return {ok: true, ts0: 8, tsLen: L, counter: counter}
    }
    catch e
    {
        return {ok: false, why: "Cloud layout not recognised (" . e.Message . ")"}
    }
}

; Pure: builds the Cloud value to write (counter advanced by delta).
PlanCloud(hex, delta) {
    if (hex = "")
        return {ok: false, outcome: "absent", why: "Cloud value not present"}
    if !IsHex(hex)
        return {ok: false, outcome: "malformed", why: "Cloud value is not binary"}
    try
    {
        b := HexToBytes(hex)
        ci := CloudParse(b)
        if !ci.ok
            return {ok: false, outcome: "malformed", why: ci.why}
        if (delta < 1 || ci.counter > 9223372036854775807 - delta)
            return {ok: false, outcome: "malformed", why: "counter overflow: Cloud counter + delta would reach 2^63"}
        newC := ci.counter + delta
        enc := EncodeVarint(newC)
        nb := b.Clone()
        nb.RemoveAt(ci.ts0, ci.tsLen)
        nb.InsertAt(ci.ts0, enc*)
        chk := CloudParse(nb)
        if (!chk.ok || chk.counter != newC)
            return {ok: false, outcome: "malformed", why: "internal check of the Cloud value failed"}
        return {ok: true, bytes: nb, hex: BytesToHex(nb), counter: newC, oldCounter: ci.counter}
    }
    catch e
    {
        return {ok: false, outcome: "malformed", why: "exception: " . e.Message}
    }
}

; Returns {outcome, why}; outcome is written / already / absent / malformed / mismatch.
MirrorCloud(snapHex, delta) {
    global KEY_CLOUD, MIRROR_WAIT_MS
    Sleep, %MIRROR_WAIT_MS%
    nowHex := ""
    if !ReadReg(KEY_CLOUD, nowHex)
        return {outcome: "absent", why: "Cloud value not present"}
    if !(nowHex == snapHex)
        return {outcome: "already", why: "shell already updated Cloud"}

    plan := PlanCloud(nowHex, delta)
    if !plan.ok
        return {outcome: plan.outcome, why: plan.why}

    if !WriteReg(KEY_CLOUD, plan.hex)
        return {outcome: "mismatch", why: "RegWrite failed"}

    chkHex := ""
    if !ReadReg(KEY_CLOUD, chkHex)
        return {outcome: "mismatch", why: "Cloud value missing after write"}
    if !IsHex(chkHex)
        return {outcome: "mismatch", why: "Cloud value not binary after write"}
    ci := CloudParse(HexToBytes(chkHex))
    if (!ci.ok || ci.counter != plan.counter)
        return {outcome: "mismatch", why: "Cloud counter after write is not the expected " . plan.counter}
    return {outcome: "written", why: ""}
}

; ---------------------------------------------------------------------------
; Registry, export and log helpers
; ---------------------------------------------------------------------------
ReadReg(sub, ByRef hex) {
    global VAL
    RegRead, hex, HKCU, %sub%, %VAL%
    if (ErrorLevel)
    {
        hex := ""
        return false
    }
    StringUpper, hex, hex
    return true
}

WriteReg(sub, hex) {
    global VAL
    RegWrite, REG_BINARY, HKCU, %sub%, %VAL%, %hex%
    return !ErrorLevel
}

RegSection(sub, hex) {
    global VAL
    s := "[HKEY_CURRENT_USER\" . sub . "]`r`n"
    s .= """" . VAL . """=hex:"
    n := StrLen(hex) // 2
    Loop, %n%
    {
        s .= SubStr(hex, A_Index * 2 - 1, 2)
        if (A_Index < n)
        {
            s .= ","
            if (Mod(A_Index, 24) = 0)
                s .= "\`r`n  "
        }
    }
    s .= "`r`n`r`n"
    return s
}

; .reg backup of the values as they were before our first write. Non-fatal.
ExportReg(curHex, cloudHex) {
    global KEY_SUB, KEY_CLOUD
    path := A_ScriptDir . "\nightlight_backup_" . A_Now . ".reg"
    try
    {
        f := FileOpen(path, "w", "UTF-16")
        if !IsObject(f)
            return false
        f.Write("Windows Registry Editor Version 5.00`r`n`r`n")
        f.Write(RegSection(KEY_SUB, curHex))
        if (cloudHex != "")
            f.Write(RegSection(KEY_CLOUD, cloudHex))
        f.Close()
    }
    catch e
    {
        return false
    }
    return true
}

; Never writes in dry run. Rotates to .old above LOG_MAX. Never throws.

AppendLog(result, oldHex, newHex, mirror) {
    global DRY_RUN, ENABLE_LOG, LOG_MAX
    if (DRY_RUN || !ENABLE_LOG)
        return

    path := A_ScriptDir . "\nightlight_log.txt"
    try
    {
        if FileExist(path)
        {
            sz := FileOpen(path, "r").Length
            if (sz > LOG_MAX)
            {
                FileDelete, %path%.old
                FileMove, %path%, %path%.old
            }
        }
        FormatTime, ts, , yyyy-MM-dd HH:mm:ss
        line := ts . " | " . result . " | old=" . oldHex . " | new=" . newHex . " | mirror=" . mirror
        
        f := FileOpen(path, "a", "UTF-8")
        if IsObject(f)
        {
            f.Write(line . "`r`n")
            f.Close()
        }
    }
    catch e
    {
        MsgBox, 16, Log Error, % "Failed to write log: " . e.Message
    }
}

HideTip() {
    ToolTip
}

ShowTip(text) {
    global SHOW_TOAST
    if (!SHOW_TOAST)
        return
    ToolTip, % text
    fn := Func("HideTip")
    SetTimer, % fn, -900
}
; ---------------------------------------------------------------------------
; The toggle itself
; ---------------------------------------------------------------------------
; Reentrancy guard + debounce. "last" is stamped when the WHOLE operation
; (including the Cloud mirror and its wait) has finished.
ToggleNightLight() {
    global DEBOUNCE_MS
    static busy := false
    static last := 0
    if (busy || (A_TickCount - last < DEBOUNCE_MS))
        return
    busy := true
    try
    {
        DoToggle()
    }
    finally
    {
        busy := false
        last := A_TickCount
    }
}

DoToggle() {
    global DRY_RUN, KEY_SUB, KEY_CLOUD, FORCE_STATE, ENABLE_BACKUP
    static exported := false
    title := "Night Light toggle"

    hex := ""
    if !ReadReg(KEY_SUB, hex)
    {
        MsgBox, 16, % title, % "Could not read the Night Light value."
            . "`n`nIf you just deleted the key, switch Night Light once from Quick Settings (Win+A) so Windows recreates it."
        return
    }
    if !IsHex(hex)
    {
        MsgBox, 16, % title, % "Not changing anything: the Night Light value is not a binary value.`n`nCurrent value:`n" . hex
        AppendLog("REFUSED: value is not binary", hex, "-", "-")
        return
    }

    ; Snapshot of Cloud before we touch anything (used for the stale check).
    cloudSnap := ""
    ReadReg(KEY_CLOUD, cloudSnap)

    target := ""
    if (FORCE_STATE = "on")
        target := 1
    else if (FORCE_STATE = "off")
        target := 0

    nowFT := GetNowFileTime()          ; the single clock read for this toggle
    r := ToggleBytes(HexToBytes(hex), nowFT, target)
    if !r.ok
    {
        MsgBox, 16, % title, % "Not changing anything: " . r.why . "`n`nCurrent value:`n" . hex
        AppendLog("REFUSED: " . r.why, hex, "-", "-")
        return
    }

    if (r.noop)
    {
        word := r.willBeOn ? "on" : "off"
        if (DRY_RUN)
            MsgBox, 0, % title, % "DRY RUN - nothing was written.`n`nNight Light is already " . word . ", so there is nothing to do."
        else
        {
            ShowTip("Night Light already " . word)
            AppendLog("NOOP: already " . word, hex, "-", "-")
        }
        return
    }

    newHex := BytesToHex(r.bytes)

    if (DRY_RUN)
    {
        plan := PlanCloud(cloudSnap, r.delta)
        msg := "DRY RUN - nothing was written.`n`nNight Light is currently " . (r.wasOn ? "ON" : "OFF") . "."
        msg .= "`nCounter: " . r.oldCounter . " -> " . r.counter . " (" . r.rule . ", delta " . r.delta . ")"
        msg .= "`n`nCurrent (" . (StrLen(hex) // 2) . " bytes):`n" . hex
        msg .= "`n`nWould write (" . (StrLen(newHex) // 2) . " bytes):`n" . newHex
        if (plan.ok)
        {
            msg .= "`n`nCloud now (" . (StrLen(cloudSnap) // 2) . " bytes):`n" . cloudSnap
            msg .= "`n`nCloud delta that would be written (" . (StrLen(plan.hex) // 2) . " bytes, after a 150 ms wait and stale check):`n" . plan.hex
        }
        else
            msg .= "`n`nCloud mirror would be skipped: " . plan.outcome . " (" . plan.why . ")"
        MsgBox, 0, % title, % msg
        return
    }

    ; ---- live write -------------------------------------------------------
    note := ""
    if (ENABLE_BACKUP && !exported)
    {
        if ExportReg(hex, cloudSnap)
            exported := true
        else
            note := " [backup .reg export failed]"
    }

    if !WriteReg(KEY_SUB, newHex)
    {
        MsgBox, 16, % title, % "Write failed.`n`nNothing was changed."
        AppendLog("FAILED: RegWrite error" . note, hex, newHex, "skipped")
        return
    }

    ; Parse-based verification: the shell may already have re-encoded the value.
    verified := false
    chkHex := ""
    if (ReadReg(KEY_SUB, chkHex) && IsHex(chkHex))
    {
        cb := ParseBlob(HexToBytes(chkHex))
        if (cb.ok && cb.isOn = r.willBeOn)
            verified := true
    }
    if (!verified)
    {
        MsgBox, 16, % title, % "The value could not be verified after writing (it does not parse, or the state did not change)."
            . "`n`nPrevious value is saved in the log and the .reg backup."
        AppendLog("UNVERIFIED: state did not flip" . note, hex, newHex, "skipped")
        return
    }

    ; Feedback first: the toggle is done and verified; the mirror runs after.
    ShowTip("Night Light " . (r.wasOn ? "off" : "on"))

    ; Cloud mirror: must never abort or fail the toggle.
    m := {outcome: "malformed", why: "mirror did not run"}
    try
    {
        m := MirrorCloud(cloudSnap, r.delta)
    }
    catch e
    {
        m := {outcome: "malformed", why: "exception: " . e.Message}
    }
    mirrorTxt := m.outcome . ((m.why != "") ? " (" . m.why . ")" : "")

    AppendLog("OK " . (r.wasOn ? "ON->OFF" : "OFF->ON") . " counter " . r.oldCounter . "->" . r.counter . " (" . r.rule . ")" . note, hex, newHex, mirrorTxt)
}

; ---------------------------------------------------------------------------
; Self-test: runs the same code on blobs exported from Windows itself plus
; synthetic blobs. Touches nothing in the registry.
; ---------------------------------------------------------------------------
Check(results, name, cond) {
    results.Push([name, cond ? 1 : 0])
}

; Parses the blob from a toggle result (or returns a not-ok object).
PB(r) {
    if (r.ok && IsObject(r.bytes))
        return ParseBlob(r.bytes)
    return {ok: false, why: "toggle did not produce a blob"}
}

; Builds a Current blob. width may be larger than natural (padded varint).
BuildBlob(counter, width, isOn, ft) {
    b := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06]
    c := []
    Loop, %width%
        c.Push(0)
    WriteVarint(c, 1, width, counter)
    for _, v in c
        b.Push(v)
    for _, v in [0x2A, 0x2B, 0x0E]
        b.Push(v)
    flagIdx := b.Length() + 1
    b.Push(0)
    q := b.Length() + 1
    for _, v in [0x43, 0x42, 0x01, 0x00]
        b.Push(v)
    if (isOn)
    {
        b.Push(0x10)
        b.Push(0x00)
    }
    for _, v in [0xD0, 0x0A, 0x02, 0xC6, 0x14]
        b.Push(v)
    f := []
    Loop, 9
        f.Push(0)
    WriteVarint(f, 1, 9, ft)
    for _, v in f
        b.Push(v)
    Loop, 4
        b.Push(0)
    ftEnd := b.Length() - 4
    b[flagIdx] := (ftEnd - q + 1) + 1
    return b
}

BuildCloud(counter, width) {
    b := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26]
    c := []
    Loop, %width%
        c.Push(0)
    WriteVarint(c, 1, width, counter)
    for _, v in c
        b.Push(v)
    b.Push(0)
    return b
}

SelfTest() {
    results := []
    ft1 := UnixToFT(1794000000)
    ft2 := UnixToFT(1794000100)
    ft3 := UnixToFT(1794000200)

    ; ---- captured Windows blobs -------------------------------------------
    blobOn1 := HexToBytes("434201000A0201002A069D818080EB2A2A2B0E15434201001000D00A02C614F59ADBF99691DCEE0100000000")
    blobOff := HexToBytes("434201000A0201002A069F818080EB2A2A2B0E1343420100D00A02C614AC97C79C9991DCEE0100000000")
    blobOn2 := HexToBytes("434201000A0201002A06A1818080EB2A2A2B0E15434201001000D00A02C614F7F1E8EC9991DCEE0100000000")
    pf := ParseBlob(blobOff)
    pn := ParseBlob(blobOn2)

    r := ToggleBytes(blobOn1, pf.ft)
    Check(results, "ON -> OFF reproduces Windows' own OFF blob" . Diff(r, blobOff), r.ok && BytesToHex(r.bytes) == BytesToHex(blobOff))

    r := ToggleBytes(blobOff, pn.ft)
    Check(results, "OFF -> ON reproduces Windows' own ON blob" . Diff(r, blobOn2), r.ok && BytesToHex(r.bytes) == BytesToHex(blobOn2))

    ; ---- refusals ---------------------------------------------------------
    bad := blobOff.Clone()
    bad[ParseBlob(blobOff).flagIdx] := 0x00
    r := ToggleBytes(bad, ft1)
    Check(results, "unknown state byte is refused", !r.ok)

    bad := blobOn1.Clone()
    bad.Pop()
    r := ToggleBytes(bad, ft1)
    Check(results, "truncated blob is refused", !r.ok)

    bad := blobOff.Clone()
    bad.Push(0x00)
    r := ToggleBytes(bad, ft1)
    Check(results, "blob with an extra byte is refused", !r.ok)

    bad := blobOn1.Clone()
    bad[ParseBlob(blobOn1).insIdx] := 0x11
    r := ToggleBytes(bad, ft1)
    Check(results, "ON blob without its 10 00 marker is refused", !r.ok)

    bad := blobOff.Clone()
    bad[10] := 0x07
    r := ToggleBytes(bad, ft1)
    Check(results, "byte 10 other than 06 is refused", !r.ok)

    ; ---- 5-byte counter: stored+2 wins, two toggles restore ----------------
    base := 20000000000
    b0 := BuildBlob(base, 5, false, ft1)
    p0 := ParseBlob(b0)
    Check(results, "5-byte OFF blob parses (41 bytes, width 5)", p0.ok && b0.Length() = 41 && p0.tsLen = 5 && !p0.isOn)
    r1 := ToggleBytes(b0, ft2)
    p1 := PB(r1)
    Check(results, "5-byte OFF -> ON (43 bytes, counter+2, stored+2 wins)", r1.ok && p1.ok && p1.isOn && r1.bytes.Length() = 43 && p1.tsLen = 5 && p1.counter = base + 2 && r1.rule = "stored+2" && r1.delta = 2 && p1.ft = ft2)
    r2 := ToggleBytes(r1.bytes, ft3)
    p2 := PB(r2)
    Check(results, "5-byte ON -> OFF restores OFF (41 bytes, counter+4, fresh time)", r2.ok && p2.ok && !p2.isOn && r2.bytes.Length() = 41 && p2.counter = base + 4 && p2.ft = ft3 && GetB(r2.bytes, p2.flagIdx) = 0x13)

    ; ---- 6-byte counter ---------------------------------------------------
    base6 := 1471831000000
    b0 := BuildBlob(base6, 6, true, ft1)
    p0 := ParseBlob(b0)
    Check(results, "6-byte ON blob parses (44 bytes, width 6)", p0.ok && b0.Length() = 44 && p0.tsLen = 6 && p0.isOn)
    r1 := ToggleBytes(b0, ft2)
    p1 := PB(r1)
    Check(results, "6-byte ON -> OFF (42 bytes, counter+2)", r1.ok && p1.ok && !p1.isOn && r1.bytes.Length() = 42 && p1.counter = base6 + 2 && GetB(r1.bytes, p1.flagIdx) = 0x13)
    r2 := ToggleBytes(r1.bytes, ft3)
    p2 := PB(r2)
    Check(results, "6-byte OFF -> ON restores ON (44 bytes, counter+4)", r2.ok && p2.ok && p2.isOn && r2.bytes.Length() = 44 && p2.counter = base6 + 4 && GetB(r2.bytes, p2.flagIdx) = 0x15)

    ; ---- max rule: UnixNow wins (width grows 2 -> 5) ------------------------
    b0 := BuildBlob(1000, 2, false, ft1)
    r1 := ToggleBytes(b0, ft2)
    p1 := PB(r1)
    Check(results, "UnixNow wins when stored+2 is smaller (width 2 -> 5, flag index moves)", r1.ok && p1.ok && p1.isOn && p1.counter = 1794000100 && r1.rule = "now" && p1.tsLen = 5 && p1.flagIdx = 19 && r1.bytes.Length() = 43 && r1.delta = 1794000100 - 1000)

    ; ---- width shrink: padded 6-byte counter re-encodes at natural 5 --------
    bS := BuildBlob(1000000000, 6, true, ft1)
    pS := ParseBlob(bS)
    r1 := ToggleBytes(bS, ft2)
    p1 := PB(r1)
    Check(results, "padded 6-byte counter shrinks to 5 bytes, flag index correct", pS.ok && pS.tsLen = 6 && r1.ok && p1.ok && !p1.isOn && p1.tsLen = 5 && p1.flagIdx = 19 && r1.bytes.Length() = 41 && p1.counter = 1794000100 && GetB(r1.bytes, p1.flagIdx) = 0x13)

    ; ---- idempotence --------------------------------------------------------
    r := ToggleBytes(blobOff, ft1, 0)
    Check(results, "target OFF on an OFF blob is a no-op", r.ok && r.noop && BytesToHex(r.bytes) == BytesToHex(blobOff))
    r := ToggleBytes(blobOff, ft1, 1)
    Check(results, "target ON on an OFF blob toggles", r.ok && !r.noop && PB(r).isOn)

    ; ---- overflow refusals (nothing is modified) ----------------------------
    bO := BuildBlob(9223372036854775806, 9, false, ft1)
    hexBefore := BytesToHex(bO)
    r := ToggleBytes(bO, ft2)
    Check(results, "counter 2^63-2 is refused (overflow), blob untouched", !r.ok && InStr(r.why, "overflow") && BytesToHex(bO) == hexBefore)

    bO := BuildBlob(9223372036854775807, 9, true, ft1)
    r := ToggleBytes(bO, ft2)
    Check(results, "counter 2^63-1 is refused (overflow)", !r.ok && InStr(r.why, "overflow"))

    bO := BuildBlob(5, 10, false, ft1)
    r := ToggleBytes(bO, ft2)
    Check(results, "10-byte counter is refused (overflow)", !r.ok && InStr(r.why, "overflow"))

    ; ---- Cloud shape validation and mirroring -------------------------------
    cOK := BuildCloud(1700000000, 5)
    ci := CloudParse(cOK)
    Check(results, "Cloud: valid 13-byte value parses", ci.ok && cOK.Length() = 13 && ci.counter = 1700000000)

    plan := PlanCloud(BytesToHex(cOK), 2)
    Check(results, "Cloud: counter advances by the delta, stays 13 bytes ending in 00", plan.ok && plan.counter = 1700000002 && plan.bytes.Length() = 13 && GetB(plan.bytes, 13) = 0x00)

    bad := cOK.Clone()
    bad[bad.Length()] := 0x01
    Check(results, "Cloud: value not ending in 00 is refused", !CloudParse(bad).ok)

    bad := cOK.Clone()
    bad.Push(0x00)
    Check(results, "Cloud: extra trailing byte is refused", !CloudParse(bad).ok)

    bad := cOK.Clone()
    bad[6] := 0x01
    Check(results, "Cloud: wrong header is refused", !CloudParse(bad).ok)

    bad := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26, 0x01, 0x00]
    Check(results, "Cloud: too-short value is refused", !CloudParse(bad).ok)

    bad := [0x43, 0x42, 0x01, 0x00, 0x0A, 0x00, 0x26]
    Loop, 10
        bad.Push(0x81)
    Check(results, "Cloud: unterminated varint is refused", !CloudParse(bad).ok)

    Check(results, "Cloud: absent value is reported as absent", PlanCloud("", 2).outcome = "absent")
    Check(results, "Cloud: non-hex value is reported as malformed", PlanCloud("ZZ", 2).outcome = "malformed")
    Check(results, "Cloud: malformed blob is reported as malformed", PlanCloud(BytesToHex(bad), 2).outcome = "malformed")

    cO := BuildCloud(9223372036854775806, 9)
    plan := PlanCloud(BytesToHex(cO), 2)
    Check(results, "Cloud: counter that would reach 2^63 is refused (overflow)", !plan.ok && InStr(plan.why, "overflow"))


   ; ---- report -------------------------------------------------------------
    passed := 0
    for _, item in results
    {
        if (item[2])
            passed++
    }
    total := results.Length()
    failed := total - passed
    icon := (failed = 0) ? 0x40 : 0x10
    MsgBox, % icon, Night Light toggle, % "Self-test: " . passed . "/" . total . " passed. " . failed . " failed."
        . "`nIf all passed, manually set DRY_RUN := false"
}

; Debug helper: explains why a toggle result differs from the expected blob.
Diff(r, expected) {
    if !r.ok
        return "`n      -> refused: " . r.why
    got := r.bytes
    if (got.Length() != expected.Length())
        return "`n      -> length " . got.Length() . " vs expected " . expected.Length()
    for i, v in expected
    {
        if (got[i] != v)
            return "`n      -> first diff at byte " . i . ": got " . Format("{:02X}", got[i]) . ", expected " . Format("{:02X}", v)
    }
    return ""
}

; ---------------------------------------------------------------------------
; Hotkey (keep at the bottom). KeyWait stops a held key from auto-repeating.
; ---------------------------------------------------------------------------
^!n:: 
    ToggleNightLight()
    KeyWait, n
return
