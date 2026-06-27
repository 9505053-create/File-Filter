#Requires AutoHotkey v2.0
#SingleInstance Force

; =====================================================================
;  資料夾即時篩選器 (FolderFilter)  v1.1
;  熱鍵（可在設定中變更，預設 Ctrl+Alt+F）：對目前檔案總管資料夾叫出篩選視窗
;
;  v1.1 變更（依 3CLI 審查）：
;   - 即時過濾加 180ms debounce（大資料夾不再每鍵卡死）
;   - 單遍掃描（FDR），遞迴 I/O 減半
;   - 右鍵先選取游標所在列；空白處只開放貼上/調整欄寬（避免誤刪錯檔）
;   - 改名做檔名合法性驗證；貼上防止把資料夾貼到自身/子目錄
;   - CF_HDROP 失敗路徑釋放記憶體；剪下貼上成功後清空剪貼簿
;   - 萬用字元 token 預編譯；掃描/排序/顯示上限會在狀態列提示
;   - 重開保留篩選字、勾選、視窗位置大小
;   - 批次失敗彙總一次顯示；刪除/剪貼簿操作需明確選取
;   - 新增「選資料夾」按鈕（Win11 多分頁抓不到時的退路）
;  v1.1 新功能：
;   - 右鍵選單「複製路徑」下方新增「開啟路徑」（在檔案總管定位該項目）
;   - 捷徑數量可在設定中增減（最少 10 組）
; =====================================================================

global gGui := 0, gEdit := 0, gLV := 0, gPathTxt := 0, gStatus := 0, gSB := 0
global gItems := [], gCurrentFolder := "", gScanTruncated := false
global gChkSub := 0, gChkExc := 0, gChkExclDir := 0, gChkExclFile := 0
global gChkSmall := 0, gChkBig := 0, gChkOld := 0, gChkNew := 0
global gEditKB := 0, gEditKBBig := 0, gEditDays := 0, gEditDaysNew := 0
global gScBtns := [], gShortTop := 0, gSBH := 24, gHeaderHwnd := 0
global gSortCol := 0, gSortDir := 1
global gHotkey := "^!f", gHotkeyActive := "", gShortcuts := []
global COL_PATH := 7     ; 名稱1 副檔名2 大小3 類型4 修改5 建立6 路徑7(隱藏)
global CF_HDROP := 15, GHND := 0x0042
global INI := A_ScriptDir "\FolderFilter.ini"
global RUNKEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run", RUNVAL := "FolderFilter"
global SCAN_CAP := 200000, SORT_CAP := 20000, DISP_CAP := 5000
; 重開保留的 UI 狀態
global gSt := Map("filter", "", "sub", 0, "exc", 0, "exclDir", 0, "exclFile", 0,
    "small", 0, "big", 0, "old", 0, "new", 0,
    "kb", "100", "kbBig", "10240", "days", "30", "daysNew", "7",
    "x", "", "y", "", "w", 820, "h", 680)
; 設定視窗暫存
global gSetGui := 0, gSetState := 0, gSetHk := 0, gSetAuto := 0, gSetNames := [], gSetPaths := []

LoadConfig()
RegisterHotkey()
OnMessage(0x7B, OnHeaderContext)   ; 標題列右鍵調整欄寬
A_TrayMenu.Add("設定", (*) => ShowSettings())
A_TrayMenu.Add("離開", (*) => ExitApp())

; ===================== 設定檔 =====================
LoadConfig() {
    global gHotkey, gShortcuts, INI
    gHotkey := IniRead(INI, "General", "Hotkey", "^!f")
    cnt := IniRead(INI, "Shortcuts", "Count", "10")
    cnt := (IsInteger(cnt) && cnt + 0 >= 10) ? cnt + 0 : 10
    gShortcuts := []
    loop cnt {
        n := IniRead(INI, "Shortcuts", A_Index "Name", "")
        p := IniRead(INI, "Shortcuts", A_Index "Path", "")
        gShortcuts.Push({ name: n, path: p })
    }
}

SaveConfig() {
    global gHotkey, gShortcuts, INI
    IniWrite(gHotkey, INI, "General", "Hotkey")
    IniWrite(gShortcuts.Length, INI, "Shortcuts", "Count")
    loop gShortcuts.Length {
        IniWrite(gShortcuts[A_Index].name, INI, "Shortcuts", A_Index "Name")
        IniWrite(gShortcuts[A_Index].path, INI, "Shortcuts", A_Index "Path")
    }
    i := gShortcuts.Length + 1
    loop 50 {
        try IniDelete(INI, "Shortcuts", i "Name")
        try IniDelete(INI, "Shortcuts", i "Path")
        i++
    }
}

RegisterHotkey() {
    global gHotkey, gHotkeyActive
    if (gHotkeyActive != "") {
        try Hotkey(gHotkeyActive, "Off")
    }
    try {
        Hotkey(gHotkey, (*) => ShowFilter(), "On")
        gHotkeyActive := gHotkey
    } catch as e {
        TopMsg("熱鍵註冊失敗：" gHotkey "`n" e.Message, "錯誤")
    }
}

IsAutoStart() {
    global RUNKEY, RUNVAL
    try return RegRead(RUNKEY, RUNVAL) != ""
    catch
        return false
}

SetAutoStart(enable) {
    global RUNKEY, RUNVAL
    if enable {
        cmd := A_IsCompiled ? ('"' A_ScriptFullPath '"') : ('"' A_AhkPath '" "' A_ScriptFullPath '"')
        RegWrite(cmd, "REG_SZ", RUNKEY, RUNVAL)
    } else
        try RegDelete(RUNKEY, RUNVAL)
}

; ===================== 主視窗 =====================
ShowFilter() {
    global gGui, gEdit, gCurrentFolder
    if (gGui && WinActive("ahk_id " gGui.Hwnd)) {
        gEdit.Focus()
        return
    }
    folder := GetActiveExplorerPath()
    if (folder != "")
        gCurrentFolder := folder
    BuildGui()
    ScanItems()
    UpdatePathText()
    DoFilter()
    ShowGui()
    gEdit.Focus()
}

ShowGui() {
    global gGui, gSt
    if (gSt["x"] = "")
        gGui.Show("w" gSt["w"] " h" gSt["h"])
    else
        gGui.Show("x" gSt["x"] " y" gSt["y"] " w" gSt["w"] " h" gSt["h"])
}

GetActiveExplorerPath() {
    cls := WinGetClass("A")
    if (cls != "CabinetWClass" && cls != "ExploreWClass")
        return ""
    hwnd := WinExist("A")
    shell := ComObject("Shell.Application")
    for win in shell.Windows {
        try {
            if (win.HWND = hwnd)
                return win.Document.Folder.Self.Path
        }
    }
    return ""
}

BuildGui() {
    global gGui, gEdit, gLV, gPathTxt, gStatus, gSB, gSt
    global gChkSub, gChkExc, gChkExclDir, gChkExclFile
    global gChkSmall, gChkBig, gChkOld, gChkNew, gEditKB, gEditKBBig, gEditDays, gEditDaysNew
    global gScBtns, gShortTop, gSBH, gHeaderHwnd
    if gGui {
        try SetTimer(DoFilter, 0)
        try gGui.Destroy()
        gGui := 0
    }
    gGui := Gui("+AlwaysOnTop +Resize +MinSize640x500", "資料夾篩選")
    gGui.SetFont("s10", "Segoe UI")
    gGui.MarginX := 10, gGui.MarginY := 10

    gPathTxt := gGui.AddText("xm w800", "")
    gEdit := gGui.AddEdit("xm w800")
    gEdit.Value := gSt["filter"]
    gEdit.OnEvent("Change", (*) => ScheduleFilter())

    gChkSub := gGui.AddCheckbox("xm", "含子資料夾"), gChkSub.Value := gSt["sub"]
    gChkExc := gGui.AddCheckbox("x+24 yp", "排除關鍵字"), gChkExc.Value := gSt["exc"]
    gChkExclDir := gGui.AddCheckbox("x+24 yp", "排除資料夾"), gChkExclDir.Value := gSt["exclDir"]
    gChkExclFile := gGui.AddCheckbox("x+24 yp", "排除檔案"), gChkExclFile.Value := gSt["exclFile"]
    gChkSub.OnEvent("Click", (*) => OnModeChange())
    gChkExc.OnEvent("Click", (*) => DoFilter())
    gChkExclDir.OnEvent("Click", (*) => DoFilter())
    gChkExclFile.OnEvent("Click", (*) => DoFilter())

    gChkSmall := gGui.AddCheckbox("xm", "排除小於"), gChkSmall.Value := gSt["small"]
    gEditKB := gGui.AddEdit("x+6 yp w64", gSt["kb"])
    gGui.AddText("x+4 yp", "KB 的檔案")
    gChkBig := gGui.AddCheckbox("x+24 yp", "排除大於"), gChkBig.Value := gSt["big"]
    gEditKBBig := gGui.AddEdit("x+6 yp w64", gSt["kbBig"])
    gGui.AddText("x+4 yp", "KB 的檔案")

    gChkOld := gGui.AddCheckbox("xm", "排除"), gChkOld.Value := gSt["old"]
    gEditDays := gGui.AddEdit("x+6 yp w64", gSt["days"])
    gGui.AddText("x+4 yp", "天前的檔案")
    gChkNew := gGui.AddCheckbox("x+24 yp", "排除"), gChkNew.Value := gSt["new"]
    gEditDaysNew := gGui.AddEdit("x+6 yp w64", gSt["daysNew"])
    gGui.AddText("x+4 yp", "天以後的檔案")

    for c in [gChkSmall, gChkBig, gChkOld, gChkNew]
        c.OnEvent("Click", (*) => DoFilter())
    for c in [gEditKB, gEditKBBig, gEditDays, gEditDaysNew]
        c.OnEvent("Change", (*) => ScheduleFilter())

    btnShot := gGui.AddButton("xm w70", "截圖")
    btnSet := gGui.AddButton("x+6 yp w70", "設定")
    btnRef := gGui.AddButton("x+6 yp w90", "強制刷新")
    btnPick := gGui.AddButton("x+6 yp w90", "選資料夾")
    btnShot.OnEvent("Click", (*) => Screenshot())
    btnSet.OnEvent("Click", (*) => ShowSettings())
    btnRef.OnEvent("Click", (*) => Refresh())
    btnPick.OnEvent("Click", (*) => PickFolder())

    gScBtns := []
    loop gShortcuts.Length {
        i := A_Index
        b := gGui.AddButton((i = 1 ? "xm" : "x+5 yp") " w100 h26", ShortcutLabel(i))
        b.OnEvent("Click", ShortcutClick.Bind(i))
        gScBtns.Push(b)
    }
    gScBtns[1].GetPos(, &sy)
    gShortTop := sy

    gStatus := gGui.AddText("xm w800", "")

    gLV := gGui.AddListView("xm w800 r12 Grid NoSort",
        ["名稱", "副檔名", "大小", "類型", "修改日期", "建立日期", "路徑"])
    gLV.ModifyCol(1, 250)
    gLV.ModifyCol(2, 70)
    gLV.ModifyCol(3, "85 Right")
    gLV.ModifyCol(4, 60)
    gLV.ModifyCol(5, 120)
    gLV.ModifyCol(6, 120)
    gLV.ModifyCol(7, 0)
    gLV.OnEvent("DoubleClick", (*) => OpenSelected())
    gLV.OnEvent("ContextMenu", ShowCtxMenu)
    gLV.OnEvent("ColClick", OnColClick)
    gLV.OnEvent("ItemSelect", (*) => UpdateSelStatus())
    gLV.OnEvent("ItemFocus", (*) => UpdateSelStatus())
    gHeaderHwnd := SendMessage(0x101F, 0, 0, gLV.Hwnd)

    gSB := gGui.AddStatusBar()

    gGui.OnEvent("Escape", (*) => SaveOnHide())
    gGui.OnEvent("Close", (*) => SaveOnHide())
    gGui.OnEvent("Size", GuiResize)

    gSB.GetPos(, , , &sbh)
    if sbh
        gSBH := sbh
}

SaveOnHide() {
    global gGui
    SaveUIState()
    try SetTimer(DoFilter, 0)
    gGui.Hide()
}

SaveUIState() {
    global gGui, gSt, gEdit, gChkSub, gChkExc, gChkExclDir, gChkExclFile
    global gChkSmall, gChkBig, gChkOld, gChkNew, gEditKB, gEditKBBig, gEditDays, gEditDaysNew
    if !gGui
        return
    try {
        gGui.GetClientPos(, , &cw, &ch)
        WinGetPos(&wx, &wy, , , "ahk_id " gGui.Hwnd)
        gSt["x"] := wx, gSt["y"] := wy, gSt["w"] := cw, gSt["h"] := ch
    }
    gSt["filter"] := gEdit.Value
    gSt["sub"] := gChkSub.Value, gSt["exc"] := gChkExc.Value
    gSt["exclDir"] := gChkExclDir.Value, gSt["exclFile"] := gChkExclFile.Value
    gSt["small"] := gChkSmall.Value, gSt["big"] := gChkBig.Value
    gSt["old"] := gChkOld.Value, gSt["new"] := gChkNew.Value
    gSt["kb"] := gEditKB.Value, gSt["kbBig"] := gEditKBBig.Value
    gSt["days"] := gEditDays.Value, gSt["daysNew"] := gEditDaysNew.Value
}

GuiResize(g, MinMax, W, H) {
    if (MinMax = -1)
        return
    LayoutAll(W, H)
}

LayoutAll(W, H) {
    global gPathTxt, gEdit, gStatus, gLV, gScBtns, gShortTop, gSBH
    m := 10
    w2 := (W - 2 * m < 160) ? 160 : W - 2 * m
    gPathTxt.Move(m, , w2)
    gEdit.Move(m, , w2)
    bw := 100, bh := 26, gap := 5
    perRow := (w2 + gap) // (bw + gap)
    if (perRow < 1)
        perRow := 1
    x := m, y := gShortTop, col := 0
    for b in gScBtns {
        b.Move(x, y, bw, bh)
        if (++col >= perRow) {
            col := 0, x := m, y += bh + gap
        } else
            x += bw + gap
    }
    rows := Ceil(gScBtns.Length / perRow)
    shortBottom := gShortTop + rows * (bh + gap)
    gStatus.Move(m, shortBottom + 2, w2)
    lvY := shortBottom + 26
    lvH := H - lvY - gSBH - 6
    if (lvH < 80)
        lvH := 80
    gLV.Move(m, lvY, w2, lvH)
}

UpdatePathText() {
    global gPathTxt, gCurrentFolder, gItems
    if (gCurrentFolder = "")
        gPathTxt.Value := "（尚未選擇資料夾：請開啟檔案總管後按熱鍵，或按「選資料夾」/捷徑）"
    else
        gPathTxt.Value := gCurrentFolder "　(" gItems.Length " 個項目)"
}

OnModeChange() {
    global gEdit
    Refresh()
    gEdit.Focus()
}

PickFolder() {
    global gGui, gCurrentFolder, gEdit
    gGui.Opt("-AlwaysOnTop")
    sel := DirSelect(gCurrentFolder != "" ? "*" gCurrentFolder : "", 3, "選擇要篩選的資料夾")
    gGui.Opt("+AlwaysOnTop")
    if (sel != "") {
        gCurrentFolder := sel
        Refresh()
        gEdit.Focus()
    }
}

; ===================== 掃描 / 過濾 =====================
ScanItems() {
    global gItems, gCurrentFolder, gChkSub, SCAN_CAP, gScanTruncated
    gItems := [], gScanTruncated := false
    if (gCurrentFolder = "" || !DirExist(gCurrentFolder))
        return
    rec := gChkSub.Value
    Loop Files, gCurrentFolder "\*", rec ? "FDR" : "FD" {
        isDir := InStr(A_LoopFileAttrib, "D") ? true : false
        AddItem(A_LoopFileFullPath, isDir, isDir ? -1 : A_LoopFileSize,
            A_LoopFileTimeModified, A_LoopFileTimeCreated, rec)
        if (gItems.Length >= SCAN_CAP) {
            gScanTruncated := true
            break
        }
    }
}

AddItem(fullPath, isDir, size, mtime, ctime, rec) {
    global gItems, gCurrentFolder
    SplitPath(fullPath, &nm, , &ext)
    if isDir
        ext := ""
    rel := rec ? SubStr(fullPath, StrLen(gCurrentFolder) + 2) : nm
    gItems.Push({ name: nm, rel: rel, ext: ext, size: size, isDir: isDir, mtime: mtime, ctime: ctime, path: fullPath })
}

ScheduleFilter() {
    SetTimer(DoFilter, -180)   ; debounce：連續輸入只在停頓後跑一次
}

DoFilter() {
    global gItems, gEdit, gLV, gStatus, gSortCol, SORT_CAP, DISP_CAP, SCAN_CAP, gScanTruncated
    global gChkExc, gChkExclDir, gChkExclFile, gChkSmall, gChkBig, gChkOld, gChkNew
    global gEditKB, gEditKBBig, gEditDays, gEditDaysNew
    SetTimer(DoFilter, 0)
    inc := [], exc := []
    globalExc := gChkExc.Value
    for t in StrSplit(Trim(gEdit.Value), A_Space) {
        if (t = "")
            continue
        neg := false
        if (SubStr(t, 1, 1) = "-" && StrLen(t) > 1) {
            neg := true
            t := SubStr(t, 2)
        }
        d := BuildToken(t)
        if (neg || globalExc)
            exc.Push(d)
        else
            inc.Push(d)
    }
    exclDir := gChkExclDir.Value, exclFile := gChkExclFile.Value
    kbSmall := gChkSmall.Value ? NumVal(gEditKB, 0) : 0
    kbBig := gChkBig.Value ? NumVal(gEditKBBig, 0) : 0
    cutoffOld := "", cutoffNew := ""
    if (gChkOld.Value) {
        dd := NumVal(gEditDays, 0)
        if (dd > 0)
            cutoffOld := DateAdd(A_Now, -dd, "Days")
    }
    if (gChkNew.Value) {
        dd := NumVal(gEditDaysNew, 0)
        if (dd > 0)
            cutoffNew := DateAdd(A_Now, -dd, "Days")
    }

    shown := []
    for item in gItems {
        if (item.isDir && exclDir)
            continue
        if (!item.isDir && exclFile)
            continue
        if (!item.isDir && kbSmall > 0 && item.size >= 0 && item.size < kbSmall * 1024)
            continue
        if (!item.isDir && kbBig > 0 && item.size >= 0 && item.size > kbBig * 1024)
            continue
        if (!item.isDir && cutoffOld != "" && item.mtime != "" && (item.mtime + 0) < (cutoffOld + 0))
            continue
        if (!item.isDir && cutoffNew != "" && item.mtime != "" && (item.mtime + 0) > (cutoffNew + 0))
            continue
        ok := true
        for d in inc {
            if !MatchTok(item.name, d) {
                ok := false
                break
            }
        }
        if ok {
            for d in exc {
                if MatchTok(item.name, d) {
                    ok := false
                    break
                }
            }
        }
        if ok
            shown.Push(item)
    }
    sorted := (shown.Length <= SORT_CAP)
    if sorted
        shown := MergeSort(shown, ItemCompare)

    gLV.Opt("-Redraw")
    gLV.Delete()
    total := shown.Length
    limit := (total < DISP_CAP) ? total : DISP_CAP
    loop limit {
        item := shown[A_Index]
        gLV.Add("", item.rel, item.ext, HumanSize(item.size),
            item.isDir ? "資料夾" : "檔案", FmtTime(item.mtime), FmtTime(item.ctime), item.path)
    }
    gLV.Opt("+Redraw")
    if gLV.GetCount()
        gLV.Modify(1, "Select Focus")
    note := ""
    if gScanTruncated
        note .= "（已達掃描上限 " SCAN_CAP "，可能不完整）"
    if !sorted
        note .= "（超過 " SORT_CAP " 筆未排序）"
    if (total > DISP_CAP)
        note .= "（僅顯示前 " DISP_CAP " 筆）"
    gStatus.Value := "符合 " total " 筆" note "　|　Enter/雙擊 開啟 · F2 改名 · 右鍵 選單 · Del 刪除 · Esc 關閉"
    UpdateSelStatus()
}

Refresh() {
    ScanItems()
    UpdatePathText()
    DoFilter()
}

BuildToken(t) {
    if (InStr(t, "*") || InStr(t, "?"))
        return { rx: "i)^" GlobToRegex(t) "$" }
    return { sub: t }
}

MatchTok(name, d) {
    if d.HasOwnProp("rx")
        return RegExMatch(name, d.rx) > 0
    return InStr(name, d.sub) > 0
}

GlobToRegex(glob) {
    out := ""
    loop parse glob {
        c := A_LoopField
        if (c = "*")
            out .= ".*"
        else if (c = "?")
            out .= "."
        else if InStr("\.^$|()[]{}+", c)
            out .= "\" c
        else
            out .= c
    }
    return out
}

NumVal(ctrl, default := 0) {
    v := Trim(ctrl.Value)
    return (v != "" && IsInteger(v)) ? Integer(v) : default
}

; ===================== 排序 =====================
OnColClick(LV, Col) {
    global gSortCol, gSortDir
    if (Col = gSortCol)
        gSortDir := -gSortDir
    else {
        gSortCol := Col
        gSortDir := 1
    }
    DoFilter()
}

ItemCompare(a, b) {
    global gSortCol, gSortDir
    if (gSortCol = 0) {
        if (a.isDir != b.isDir)
            return a.isDir ? -1 : 1
        return StrCompare(a.rel, b.rel, false)
    }
    c := 0
    switch gSortCol {
        case 1: c := StrCompare(a.rel, b.rel, false)
        case 2: c := StrCompare(a.ext, b.ext, false)
        case 3: c := (a.size > b.size) - (a.size < b.size)
        case 4: c := (a.isDir = b.isDir) ? 0 : (a.isDir ? -1 : 1)
        case 5: c := ((a.mtime + 0) > (b.mtime + 0)) - ((a.mtime + 0) < (b.mtime + 0))
        case 6: c := ((a.ctime + 0) > (b.ctime + 0)) - ((a.ctime + 0) < (b.ctime + 0))
        default: c := StrCompare(a.rel, b.rel, false)
    }
    if (c = 0)
        c := StrCompare(a.rel, b.rel, false)
    return c * gSortDir
}

MergeSort(arr, cmp) {
    n := arr.Length
    if (n <= 1)
        return arr
    mid := n // 2
    left := [], right := []
    loop mid
        left.Push(arr[A_Index])
    loop n - mid
        right.Push(arr[mid + A_Index])
    left := MergeSort(left, cmp)
    right := MergeSort(right, cmp)
    res := [], i := 1, j := 1
    while (i <= left.Length && j <= right.Length) {
        if (cmp(left[i], right[j]) <= 0)
            res.Push(left[i++])
        else
            res.Push(right[j++])
    }
    while (i <= left.Length)
        res.Push(left[i++])
    while (j <= right.Length)
        res.Push(right[j++])
    return res
}

HumanSize(b) {
    if (b < 0)
        return ""
    if (b < 1024)
        return b " B"
    if (b < 1048576)
        return Round(b / 1024, 1) " KB"
    if (b < 1073741824)
        return Round(b / 1048576, 1) " MB"
    return Round(b / 1073741824, 2) " GB"
}

FmtTime(stamp) {
    return (stamp = "") ? "" : FormatTime(stamp, "yyyy-MM-dd HH:mm")
}

; ===================== 標題列右鍵：調整欄寬 =====================
OnHeaderContext(wParam, lParam, msg, hwnd) {
    global gLV, gHeaderHwnd
    if (!gLV || !gHeaderHwnd || wParam != gHeaderHwnd)
        return
    ShowHeaderMenu(HeaderColAtCursor())
    return 0
}

HeaderColAtCursor() {
    global gHeaderHwnd
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    DllCall("ScreenToClient", "Ptr", gHeaderHwnd, "Ptr", pt)
    hti := Buffer(24, 0)
    NumPut("Int", NumGet(pt, 0, "Int"), hti, 0)
    NumPut("Int", NumGet(pt, 4, "Int"), hti, 4)
    idx := SendMessage(0x1206, 0, hti, gHeaderHwnd)   ; HDM_HITTEST
    return (idx >= 0 && idx <= 5) ? idx + 1 : 0
}

ShowHeaderMenu(col) {
    names := ["名稱", "副檔名", "大小", "類型", "修改日期", "建立日期"]
    m := Menu()
    if (col >= 1 && col <= 6)
        m.Add("調整「" names[col] "」欄至最適大小", FitCol.Bind(col))
    m.Add("調整所有欄位至最適大小", (*) => FitAllCols())
    m.Show()
}

FitCol(col, *) {
    global gLV
    gLV.ModifyCol(col, "AutoHdr")
}

FitAllCols() {
    global gLV
    loop 6
        gLV.ModifyCol(A_Index, "AutoHdr")
}

; ===================== 選取 / 開啟 / 狀態列 =====================
GetSelectedPaths(focusFallback := true) {
    global gLV, COL_PATH
    paths := [], row := 0
    loop {
        row := gLV.GetNext(row)
        if !row
            break
        paths.Push(gLV.GetText(row, COL_PATH))
    }
    if (!paths.Length && focusFallback) {
        f := gLV.GetNext(0, "F")
        if f
            paths.Push(gLV.GetText(f, COL_PATH))
    }
    return paths
}

IsRowSelected(row) {
    global gLV
    r := 0
    loop {
        r := gLV.GetNext(r)
        if !r
            return false
        if (r = row)
            return true
    }
}

UpdateSelStatus() {
    global gLV, gSB, COL_PATH
    cnt := 0, row := 0, last := ""
    loop {
        row := gLV.GetNext(row)
        if !row
            break
        cnt++
        last := gLV.GetText(row, COL_PATH)
    }
    if (cnt >= 2)
        gSB.SetText("已選取 " cnt " 個項目")
    else if (cnt = 1)
        gSB.SetText(last)
    else {
        f := gLV.GetNext(0, "F")
        gSB.SetText(f ? gLV.GetText(f, COL_PATH) : "")
    }
}

OpenSelected() {
    global gLV, COL_PATH
    row := gLV.GetNext(0, "F")
    if !row
        row := gLV.GetNext(0)
    if (!row && gLV.GetCount())
        row := 1
    if !row
        return
    path := gLV.GetText(row, COL_PATH)
    if (path = "")
        return
    try {
        Run(path)
        SaveOnHide()
    } catch as e {
        TopMsg("開啟失敗：`n" e.Message, "錯誤")
    }
}

OpenContainingFolder() {
    paths := GetSelectedPaths(true)
    if !paths.Length
        return
    p := paths[1]
    if !FileExist(p) {
        TopMsg("路徑不存在：`n" p, "開啟路徑")
        return
    }
    try Run('explorer.exe /select,"' p '"')
    catch as e
        TopMsg("開啟路徑失敗：`n" e.Message, "錯誤")
}

MoveSel(dir) {
    global gLV
    cnt := gLV.GetCount()
    if !cnt
        return
    cur := gLV.GetNext(0, "F")
    if !cur
        cur := gLV.GetNext(0)
    nxt := cur + dir
    if (nxt < 1)
        nxt := 1
    if (nxt > cnt)
        nxt := cnt
    gLV.Modify(0, "-Select")
    gLV.Modify(nxt, "Select Focus Vis")
    UpdateSelStatus()
}

RenameSelected() {
    global gLV, gGui, COL_PATH
    row := gLV.GetNext(0, "F")
    if !row
        row := gLV.GetNext(0)
    if !row
        return
    path := gLV.GetText(row, COL_PATH)
    if (path = "")
        return
    SplitPath(path, &nm, &dir)
    gGui.Opt("-AlwaysOnTop")
    ib := InputBox("輸入新名稱：", "重新命名", "w380 h130", nm)
    gGui.Opt("+AlwaysOnTop")
    if (ib.Result != "OK")
        return
    newName := Trim(ib.Value)
    if (newName = "" || newName = nm)
        return
    if !ValidName(newName) {
        TopMsg("名稱不合法：不可含 \ / : * ? `" < > | 或控制字元、保留裝置名（CON/PRN/AUX/NUL/COM1…），結尾不可為空白或句點。", "重新命名")
        return
    }
    newPath := dir "\" newName
    if FileExist(newPath) {
        TopMsg("已存在同名項目，無法命名。", "重新命名")
        return
    }
    try {
        if InStr(FileExist(path), "D")
            DirMove(path, newPath, "R")
        else
            FileMove(path, newPath, 0)
    } catch as e {
        TopMsg("重新命名失敗：`n" e.Message, "錯誤")
        return
    }
    Refresh()
}

ValidName(name) {
    if (name = "")
        return false
    if RegExMatch(name, '[\\/:*?"<>|]')
        return false
    if RegExMatch(name, "[\x00-\x1F]")
        return false
    if RegExMatch(name, "[ .]$")
        return false
    SplitPath(name, , , , &base)
    if RegExMatch(base, "i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$")
        return false
    return true
}

; ===================== 右鍵選單 / 檔案操作 =====================
ShowCtxMenu(LV, Item, IsRightClick, X, Y) {
    global gLV
    onEmpty := (Item = 0)
    if (Item > 0 && !IsRowSelected(Item)) {
        gLV.Modify(0, "-Select")
        gLV.Modify(Item, "Select Focus")
        UpdateSelStatus()
    }
    m := Menu()
    if !onEmpty {
        m.Add("開啟", (*) => OpenSelected())
        m.Add("重新命名`tF2", (*) => RenameSelected())
        m.Add()
        m.Add("複製路徑", (*) => CopyPathText())
        m.Add("開啟路徑", (*) => OpenContainingFolder())
        m.Add()
        m.Add("複製`tCtrl+C", (*) => ClipFiles(false))
        m.Add("剪下`tCtrl+X", (*) => ClipFiles(true))
    }
    m.Add("貼上`tCtrl+V", (*) => PasteFiles())
    if !onEmpty {
        m.Add()
        m.Add("刪除`tDel", (*) => DeleteSelected())
    }
    m.Add()
    m.Add("自動調整所有欄位寬度", (*) => FitAllCols())
    m.Show()
}

CopyPathText() {
    paths := GetSelectedPaths(true)
    if !paths.Length
        return
    s := ""
    for p in paths
        s .= (s = "" ? "" : "`n") p
    A_Clipboard := s
    Tip(paths.Length " 個路徑已複製")
}

ClipFiles(cut) {
    paths := GetSelectedPaths(false)
    if !paths.Length
        return
    if PutFilesOnClipboard(paths, cut)
        Tip((cut ? "已剪下 " : "已複製 ") paths.Length " 個項目")
    else
        TopMsg("放入剪貼簿失敗。", "錯誤")
}

PasteFiles() {
    global gCurrentFolder
    if (PasteFilesToFolder(gCurrentFolder) > 0)
        Refresh()
}

DeleteSelected() {
    paths := GetSelectedPaths(false)
    if !paths.Length
        return
    if (TopMsg("確定將選取的 " paths.Length " 個項目移到資源回收筒?", "刪除", "YesNo Icon?") != "Yes")
        return
    errs := []
    for p in paths {
        try
            FileRecycle(p)
        catch as e
            errs.Push(p " — " e.Message)
    }
    if errs.Length
        TopMsg("以下 " errs.Length " 項刪除失敗：`n" JoinN(errs, 12), "刪除")
    Refresh()
}

JoinN(arr, max) {
    s := "", n := 0
    for x in arr {
        if (++n > max) {
            s .= "`n…（其餘 " (arr.Length - max) " 項略）"
            break
        }
        s .= (s = "" ? "" : "`n") x
    }
    return s
}

PutFilesOnClipboard(paths, cut := false) {
    global CF_HDROP, GHND
    chars := 1
    for p in paths
        chars += StrLen(p) + 1
    hMem := DllCall("GlobalAlloc", "UInt", GHND, "Ptr", 20 + chars * 2, "Ptr")
    if !hMem
        return false
    pMem := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    if !pMem {
        DllCall("GlobalFree", "Ptr", hMem)
        return false
    }
    NumPut("UInt", 20, pMem, 0)
    NumPut("Int", 1, pMem, 16)
    off := 20
    for p in paths {
        StrPut(p, pMem + off, StrLen(p) + 1, "UTF-16")
        off += (StrLen(p) + 1) * 2
    }
    DllCall("GlobalUnlock", "Ptr", hMem)
    hEff := DllCall("GlobalAlloc", "UInt", GHND, "Ptr", 4, "Ptr")
    if hEff {
        pEff := DllCall("GlobalLock", "Ptr", hEff, "Ptr")
        NumPut("UInt", cut ? 2 : 1, pEff, 0)
        DllCall("GlobalUnlock", "Ptr", hEff)
    }
    if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd) {
        DllCall("GlobalFree", "Ptr", hMem)
        if hEff
            DllCall("GlobalFree", "Ptr", hEff)
        return false
    }
    DllCall("EmptyClipboard")
    okDrop := DllCall("SetClipboardData", "UInt", CF_HDROP, "Ptr", hMem, "Ptr")
    if !okDrop
        DllCall("GlobalFree", "Ptr", hMem)
    if hEff {
        cf := DllCall("RegisterClipboardFormat", "Str", "Preferred DropEffect", "UInt")
        if !DllCall("SetClipboardData", "UInt", cf, "Ptr", hEff, "Ptr")
            DllCall("GlobalFree", "Ptr", hEff)
    }
    DllCall("CloseClipboard")
    return okDrop ? true : false
}

PasteFilesToFolder(destDir) {
    global CF_HDROP
    if (destDir = "" || !DirExist(destDir))
        return 0
    if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)
        return 0
    hDrop := DllCall("GetClipboardData", "UInt", CF_HDROP, "Ptr")
    if !hDrop {
        DllCall("CloseClipboard")
        Tip("剪貼簿沒有檔案")
        return 0
    }
    cf := DllCall("RegisterClipboardFormat", "Str", "Preferred DropEffect", "UInt")
    hEff := DllCall("GetClipboardData", "UInt", cf, "Ptr")
    effect := 1
    if hEff {
        pE := DllCall("GlobalLock", "Ptr", hEff, "Ptr")
        if pE {
            effect := NumGet(pE, 0, "UInt")
            DllCall("GlobalUnlock", "Ptr", hEff)
        }
    }
    cnt := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", 0xFFFFFFFF, "Ptr", 0, "UInt", 0, "UInt")
    files := []
    Loop cnt {
        idx := A_Index - 1
        len := DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", 0, "UInt", 0, "UInt")
        buf := Buffer((len + 1) * 2, 0)
        DllCall("shell32\DragQueryFileW", "Ptr", hDrop, "UInt", idx, "Ptr", buf, "UInt", len + 1)
        files.Push(StrGet(buf, "UTF-16"))
    }
    DllCall("CloseClipboard")
    move := (effect = 2), done := 0, errs := []
    nd := RTrim(destDir, "\"), ndLo := StrLower(nd)
    for f in files {
        SplitPath(f, &nm)
        srcIsDir := InStr(FileExist(f), "D") ? true : false
        nf := RTrim(f, "\"), nfLo := StrLower(nf)
        if (srcIsDir && (ndLo = nfLo || SubStr(ndLo "\", 1, StrLen(nfLo) + 1) = nfLo "\")) {
            errs.Push(nm " — 不能貼到自身或其子資料夾")
            continue
        }
        dest := nd "\" nm
        if (dest = f) {
            if move
                continue
            dest := UniqueDest(nd, nm)
        } else if FileExist(dest)
            dest := UniqueDest(nd, nm)
        if (dest = "") {
            errs.Push(nm " — 無法產生唯一名稱")
            continue
        }
        try {
            if move
                srcIsDir ? DirMove(f, dest, 0) : FileMove(f, dest, 0)
            else
                srcIsDir ? DirCopy(f, dest, 0) : FileCopy(f, dest, 0)
            done++
        } catch as e {
            errs.Push(nm " — " e.Message)
        }
    }
    if (move && done > 0)
        ClearClipboard()
    if errs.Length
        TopMsg("以下 " errs.Length " 項貼上失敗：`n" JoinN(errs, 12), "貼上")
    if done
        Tip((move ? "已移動 " : "已貼上 ") done " 個項目")
    return done
}

ClearClipboard() {
    if DllCall("OpenClipboard", "Ptr", A_ScriptHwnd) {
        DllCall("EmptyClipboard")
        DllCall("CloseClipboard")
    }
}

UniqueDest(dir, name) {
    SplitPath(name, , , &ext, &base)
    i := 2
    loop 9999 {
        cand := dir "\" base " (" i ")" (ext != "" ? "." ext : "")
        if !FileExist(cand)
            return cand
        i++
    }
    return ""
}

; ===================== 截圖 =====================
Screenshot() {
    global gGui
    if CaptureWindowToClipboard(gGui.Hwnd)
        Tip("已截圖到剪貼簿")
}

CaptureWindowToClipboard(hwnd) {
    rc := Buffer(16, 0)
    DllCall("GetWindowRect", "Ptr", hwnd, "Ptr", rc)
    w := NumGet(rc, 8, "Int") - NumGet(rc, 0, "Int")
    h := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if (w <= 0 || h <= 0)
        return false
    hdcWin := DllCall("GetWindowDC", "Ptr", hwnd, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcWin, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcWin, "Int", w, "Int", h, "Ptr")
    hbmOld := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")
    if !DllCall("PrintWindow", "Ptr", hwnd, "Ptr", hdcMem, "UInt", 2)
        DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdcWin, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
    DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbmOld)
    if DllCall("OpenClipboard", "Ptr", hwnd) {
        DllCall("EmptyClipboard")
        DllCall("SetClipboardData", "UInt", 2, "Ptr", hbm)
        DllCall("CloseClipboard")
    } else
        DllCall("DeleteObject", "Ptr", hbm)
    DllCall("DeleteDC", "Ptr", hdcMem)
    DllCall("ReleaseDC", "Ptr", hwnd, "Ptr", hdcWin)
    return true
}

; ===================== 捷徑 =====================
ShortcutLabel(i) {
    global gShortcuts
    return (gShortcuts[i].name != "") ? gShortcuts[i].name : "捷徑" i
}

ShortcutClick(i, *) {
    global gShortcuts, gCurrentFolder, gEdit
    sc := gShortcuts[i]
    if (sc.path = "" || !DirExist(sc.path)) {
        ShowSettings()
        return
    }
    gCurrentFolder := sc.path
    Refresh()
    gEdit.Focus()
}

; ===================== 設定視窗 =====================
ShowSettings() {
    global gSetState, gShortcuts, gHotkey
    gSetState := { hotkey: gHotkey, autostart: IsAutoStart(), items: [] }
    for sc in gShortcuts
        gSetState.items.Push({ name: sc.name, path: sc.path })
    RenderSettings()
}

RenderSettings() {
    global gSetGui, gSetState, gSetHk, gSetAuto, gSetNames, gSetPaths, gGui
    if gSetGui {
        try gSetGui.Destroy()
        gSetGui := 0
    }
    own := (gGui ? "+Owner" gGui.Hwnd " " : "") "+AlwaysOnTop +ToolWindow"
    gSetGui := Gui(own, "設定")
    gSetGui.SetFont("s10", "Segoe UI")

    gSetGui.AddText("xm", "啟動熱鍵（點欄位後直接按組合鍵）：")
    gSetHk := gSetGui.AddHotkey("xm w220", gSetState.hotkey)
    gSetAuto := gSetGui.AddCheckbox("xm y+10", "開機時自動載入")
    gSetAuto.Value := gSetState.autostart ? 1 : 0

    gSetGui.AddText("xm y+14", "自訂捷徑（最少 10 組；點主視窗按鈕即切換目錄）：")
    btnAdd := gSetGui.AddButton("xm y+4 w96", "＋ 新增一組")
    btnDel := gSetGui.AddButton("x+8 yp w96", "－ 刪除一組")
    gSetGui.AddText("x+12 yp+5", "目前 " gSetState.items.Length " 組")
    btnAdd.OnEvent("Click", (*) => SettingsAddRow())
    btnDel.OnEvent("Click", (*) => SettingsDelRow())

    gSetNames := [], gSetPaths := []
    loop gSetState.items.Length {
        i := A_Index
        gSetGui.AddText("xm y+6 w46 h24 +0x200", "捷徑" i)
        ne := gSetGui.AddEdit("x+4 yp w120", gSetState.items[i].name)
        pe := gSetGui.AddEdit("x+6 yp w300", gSetState.items[i].path)
        br := gSetGui.AddButton("x+6 yp-1 w56 h24", "瀏覽")
        br.OnEvent("Click", BrowseFor.Bind(pe))
        gSetNames.Push(ne), gSetPaths.Push(pe)
    }

    ok := gSetGui.AddButton("xm y+16 w90 Default", "確定")
    cancel := gSetGui.AddButton("x+10 yp w90", "取消")
    ok.OnEvent("Click", (*) => SaveSettings())
    cancel.OnEvent("Click", (*) => gSetGui.Destroy())
    gSetGui.OnEvent("Escape", (*) => gSetGui.Destroy())
    gSetGui.Show()
}

CaptureSettings() {
    global gSetState, gSetHk, gSetAuto, gSetNames, gSetPaths
    if (gSetHk.Value != "")
        gSetState.hotkey := gSetHk.Value
    gSetState.autostart := gSetAuto.Value
    loop gSetState.items.Length {
        gSetState.items[A_Index].name := Trim(gSetNames[A_Index].Value)
        gSetState.items[A_Index].path := Trim(gSetPaths[A_Index].Value)
    }
}

SettingsAddRow() {
    global gSetState
    CaptureSettings()
    gSetState.items.Push({ name: "", path: "" })
    RenderSettings()
}

SettingsDelRow() {
    global gSetState
    CaptureSettings()
    if (gSetState.items.Length > 10)
        gSetState.items.Pop()
    else
        Tip("最少需保留 10 組")
    RenderSettings()
}

BrowseFor(pe, *) {
    global gSetGui
    if gSetGui
        gSetGui.Opt("-AlwaysOnTop")
    sel := DirSelect(pe.Value != "" ? "*" pe.Value : "", 3, "選擇資料夾")
    if gSetGui
        gSetGui.Opt("+AlwaysOnTop")
    if (sel != "")
        pe.Value := sel
}

SaveSettings() {
    global gSetState, gSetGui, gShortcuts, gHotkey, gGui, gEdit
    CaptureSettings()
    if (gSetState.hotkey != "" && gSetState.hotkey != gHotkey) {
        gHotkey := gSetState.hotkey
        RegisterHotkey()
    }
    SetAutoStart(gSetState.autostart)
    gShortcuts := []
    for it in gSetState.items
        gShortcuts.Push({ name: it.name, path: it.path })
    SaveConfig()
    gSetGui.Destroy()
    Tip("設定已儲存")
    if gGui {
        wasVisible := DllCall("IsWindowVisible", "Ptr", gGui.Hwnd)
        SaveUIState()
        BuildGui()
        if wasVisible {
            ScanItems()
            UpdatePathText()
            DoFilter()
            ShowGui()
            gEdit.Focus()
        }
    }
}

; ===================== 共用 =====================
ListFocused() {
    global gLV
    if !gLV
        return false
    try return ControlGetFocus("A") = gLV.Hwnd
    catch
        return false
}

TopMsg(text, title := "提示", opt := "") {
    return MsgBox(text, title, Trim(opt " 0x40000"))
}

Tip(msg) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -1500)
}

; ==== 視窗作用中：方向鍵 / Enter / F2 ====
#HotIf gGui && WinActive("ahk_id " gGui.Hwnd)
*Up::MoveSel(-1)
*Down::MoveSel(1)
Enter::OpenSelected()
NumpadEnter::OpenSelected()
F2::RenameSelected()
#HotIf

; ==== 只有清單有焦點時：Del / 複製剪下貼上 ====
#HotIf gGui && WinActive("ahk_id " gGui.Hwnd) && ListFocused()
Delete::DeleteSelected()
^c::ClipFiles(false)
^x::ClipFiles(true)
^v::PasteFiles()
#HotIf
