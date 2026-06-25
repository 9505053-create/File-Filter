#Requires AutoHotkey v2.0
#SingleInstance Force

; =====================================================================
;  資料夾即時篩選器 (FolderFilter)
;  熱鍵（可在設定中變更，預設 Ctrl+Alt+F）：對目前檔案總管資料夾叫出篩選視窗
;
;  關鍵字：空白分隔多組 AND；含 * 或 ? 時為萬用字元（例 *.md）；行內 -字 為排除
;  選項：含子資料夾 / 排除關鍵字 / 排除資料夾 / 排除檔案 /
;        排除小於 N KB / 排除大於 N KB / 排除 N 天前 / 排除 N 天以後 的檔案
;  按鈕：截圖 / 設定（熱鍵·開機載入·10 捷徑）/ 強制刷新
;  捷徑：10 個，依視窗寬度自動換行；點一下切換篩選目錄
;  欄位：名稱 | 副檔名 | 大小 | 類型 | 修改日期 | 建立日期（點標題排序）
;  欄寬：標題列右鍵 或 項目右鍵 可「自動調整欄位至最適大小」
;  操作：↑/↓ 選取 · Enter/雙擊 開啟 · F2 改名 · 右鍵 選單 · Del 刪除 · Esc 關閉
;  底部狀態列：單選顯示完整路徑；多選顯示數量
; =====================================================================

global gGui := 0, gEdit := 0, gLV := 0, gPathTxt := 0, gStatus := 0, gSB := 0
global gItems := [], gCurrentFolder := ""
global gChkSub := 0, gChkExc := 0, gChkExclDir := 0, gChkExclFile := 0
global gChkSmall := 0, gChkBig := 0, gChkOld := 0, gChkNew := 0
global gEditKB := 0, gEditKBBig := 0, gEditDays := 0, gEditDaysNew := 0
global gScBtns := [], gShortTop := 0, gSBH := 24, gHeaderHwnd := 0
global gSortCol := 0, gSortDir := 1
global gHotkey := "^!f", gHotkeyActive := "", gShortcuts := []
global COL_TYPE := 4, COL_PATH := 7     ; 名稱1 副檔名2 大小3 類型4 修改5 建立6 路徑7(隱藏)
global INI := A_ScriptDir "\FolderFilter.ini"
global RUNKEY := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"
global RUNVAL := "FolderFilter"
global SCAN_CAP := 200000, SORT_CAP := 20000, DISP_CAP := 5000

LoadConfig()
RegisterHotkey()
OnMessage(0x7B, OnHeaderContext)   ; WM_CONTEXTMENU → 標題列右鍵調整欄寬
A_TrayMenu.Add("設定", (*) => ShowSettings())
A_TrayMenu.Add("離開", (*) => ExitApp())

; ===================== 設定檔 =====================
LoadConfig() {
    global gHotkey, gShortcuts, INI
    gHotkey := IniRead(INI, "General", "Hotkey", "^!f")
    gShortcuts := []
    loop 10 {
        n := IniRead(INI, "Shortcuts", A_Index "Name", "")
        p := IniRead(INI, "Shortcuts", A_Index "Path", "")
        gShortcuts.Push({ name: n, path: p })
    }
}

SaveConfig() {
    global gHotkey, gShortcuts, INI
    IniWrite(gHotkey, INI, "General", "Hotkey")
    loop 10 {
        IniWrite(gShortcuts[A_Index].name, INI, "Shortcuts", A_Index "Name")
        IniWrite(gShortcuts[A_Index].path, INI, "Shortcuts", A_Index "Path")
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
    if enable
        RegWrite('"' A_AhkPath '" "' A_ScriptFullPath '"', "REG_SZ", RUNKEY, RUNVAL)
    else
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
    gEdit.Value := ""
    ScanItems()
    UpdatePathText()
    DoFilter()
    gGui.Show("w820 h680")
    gEdit.Focus()
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
    global gGui, gEdit, gLV, gPathTxt, gStatus, gSB
    global gChkSub, gChkExc, gChkExclDir, gChkExclFile
    global gChkSmall, gChkBig, gChkOld, gChkNew, gEditKB, gEditKBBig, gEditDays, gEditDaysNew
    global gScBtns, gShortTop, gSBH, gHeaderHwnd
    if gGui {
        try gGui.Destroy()
        gGui := 0
    }
    gGui := Gui("+AlwaysOnTop +Resize +MinSize640x500", "資料夾篩選")
    gGui.SetFont("s10", "Segoe UI")
    gGui.MarginX := 10, gGui.MarginY := 10

    gPathTxt := gGui.AddText("xm w800", "")
    gEdit := gGui.AddEdit("xm w800")
    gEdit.OnEvent("Change", (*) => DoFilter())

    gChkSub := gGui.AddCheckbox("xm", "含子資料夾")
    gChkExc := gGui.AddCheckbox("x+24 yp", "排除關鍵字")
    gChkExclDir := gGui.AddCheckbox("x+24 yp", "排除資料夾")
    gChkExclFile := gGui.AddCheckbox("x+24 yp", "排除檔案")
    gChkSub.OnEvent("Click", (*) => OnModeChange())
    gChkExc.OnEvent("Click", (*) => DoFilter())
    gChkExclDir.OnEvent("Click", (*) => DoFilter())
    gChkExclFile.OnEvent("Click", (*) => DoFilter())

    gChkSmall := gGui.AddCheckbox("xm", "排除小於")
    gEditKB := gGui.AddEdit("x+6 yp w64", "100")
    gGui.AddText("x+4 yp", "KB 的檔案")
    gChkBig := gGui.AddCheckbox("x+24 yp", "排除大於")
    gEditKBBig := gGui.AddEdit("x+6 yp w64", "10240")
    gGui.AddText("x+4 yp", "KB 的檔案")

    gChkOld := gGui.AddCheckbox("xm", "排除")
    gEditDays := gGui.AddEdit("x+6 yp w64", "30")
    gGui.AddText("x+4 yp", "天前的檔案")
    gChkNew := gGui.AddCheckbox("x+24 yp", "排除")
    gEditDaysNew := gGui.AddEdit("x+6 yp w64", "7")
    gGui.AddText("x+4 yp", "天以後的檔案")

    for c in [gChkSmall, gChkBig, gChkOld, gChkNew]
        c.OnEvent("Click", (*) => DoFilter())
    for c in [gEditKB, gEditKBBig, gEditDays, gEditDaysNew]
        c.OnEvent("Change", (*) => DoFilter())

    btnShot := gGui.AddButton("xm w70", "截圖")
    btnSet := gGui.AddButton("x+6 yp w70", "設定")
    btnRef := gGui.AddButton("x+6 yp w90", "強制刷新")
    btnShot.OnEvent("Click", (*) => Screenshot())
    btnSet.OnEvent("Click", (*) => ShowSettings())
    btnRef.OnEvent("Click", (*) => Refresh())

    gScBtns := []
    loop 10 {
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
    gLV.ModifyCol(7, 0)        ; 隱藏完整路徑欄
    gLV.OnEvent("DoubleClick", (*) => OpenSelected())
    gLV.OnEvent("ContextMenu", ShowCtxMenu)
    gLV.OnEvent("ColClick", OnColClick)
    gLV.OnEvent("ItemSelect", (*) => UpdateSelStatus())
    gLV.OnEvent("ItemFocus", (*) => UpdateSelStatus())
    gHeaderHwnd := SendMessage(0x101F, 0, 0, gLV.Hwnd)   ; LVM_GETHEADER

    gSB := gGui.AddStatusBar()

    gGui.OnEvent("Escape", (*) => gGui.Hide())
    gGui.OnEvent("Close", (*) => gGui.Hide())
    gGui.OnEvent("Size", GuiResize)

    gSB.GetPos(, , , &sbh)
    if sbh
        gSBH := sbh
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
        gPathTxt.Value := "（尚未選擇資料夾：請開啟檔案總管後按熱鍵，或點下方捷徑）"
    else
        gPathTxt.Value := gCurrentFolder "　(" gItems.Length " 個項目)"
}

OnModeChange() {
    global gEdit
    Refresh()
    gEdit.Focus()
}

; ===================== 掃描 / 過濾 =====================
ScanItems() {
    global gItems, gCurrentFolder, gChkSub, SCAN_CAP
    gItems := []
    if (gCurrentFolder = "" || !DirExist(gCurrentFolder))
        return
    rec := gChkSub.Value
    Loop Files, gCurrentFolder "\*", rec ? "DR" : "D" {
        AddItem(A_LoopFileFullPath, true, -1, A_LoopFileTimeModified, A_LoopFileTimeCreated, rec)
        if (gItems.Length >= SCAN_CAP)
            break
    }
    Loop Files, gCurrentFolder "\*", rec ? "FR" : "F" {
        AddItem(A_LoopFileFullPath, false, A_LoopFileSize, A_LoopFileTimeModified, A_LoopFileTimeCreated, rec)
        if (gItems.Length >= SCAN_CAP)
            break
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

DoFilter() {
    global gItems, gEdit, gLV, gStatus, gSortCol, SORT_CAP, DISP_CAP
    global gChkExc, gChkExclDir, gChkExclFile, gChkSmall, gChkBig, gChkOld, gChkNew
    global gEditKB, gEditKBBig, gEditDays, gEditDaysNew
    inc := [], exc := []
    globalExc := gChkExc.Value
    for t in StrSplit(Trim(gEdit.Value), A_Space) {
        if (t = "")
            continue
        if (SubStr(t, 1, 1) = "-" && StrLen(t) > 1)
            exc.Push(SubStr(t, 2))
        else if globalExc
            exc.Push(t)
        else
            inc.Push(t)
    }
    exclDir := gChkExclDir.Value, exclFile := gChkExclFile.Value
    kbSmall := gChkSmall.Value ? NumVal(gEditKB, 0) : 0
    kbBig := gChkBig.Value ? NumVal(gEditKBBig, 0) : 0
    cutoffOld := "", cutoffNew := ""
    if (gChkOld.Value) {
        d := NumVal(gEditDays, 0)
        if (d > 0)
            cutoffOld := DateAdd(A_Now, -d, "Days")
    }
    if (gChkNew.Value) {
        d := NumVal(gEditDaysNew, 0)
        if (d > 0)
            cutoffNew := DateAdd(A_Now, -d, "Days")
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
        for t in inc {
            if !TokenMatch(item.name, t) {
                ok := false
                break
            }
        }
        if ok {
            for t in exc {
                if TokenMatch(item.name, t) {
                    ok := false
                    break
                }
            }
        }
        if ok
            shown.Push(item)
    }
    if (shown.Length <= SORT_CAP)
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
    note := (total > DISP_CAP) ? "（僅顯示前 " DISP_CAP " 筆，請輸入更精確關鍵字）" : ""
    gStatus.Value := "符合 " total " 筆" note "　|　Enter/雙擊 開啟 · F2 改名 · 右鍵 選單 · Del 刪除 · Esc 關閉"
    UpdateSelStatus()
}

Refresh() {
    ScanItems()
    UpdatePathText()
    DoFilter()
}

TokenMatch(name, tok) {
    if (InStr(tok, "*") || InStr(tok, "?"))
        return RegExMatch(name, "i)^" GlobToRegex(tok) "$") > 0
    return InStr(name, tok) > 0
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
GetSelectedPaths() {
    global gLV, COL_PATH
    paths := [], row := 0
    loop {
        row := gLV.GetNext(row)
        if !row
            break
        paths.Push(gLV.GetText(row, COL_PATH))
    }
    if !paths.Length {
        f := gLV.GetNext(0, "F")
        if f
            paths.Push(gLV.GetText(f, COL_PATH))
    }
    return paths
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
    global gLV, gGui, COL_PATH
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
    try Run(path)
    gGui.Hide()
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

; ===================== 右鍵選單 / 檔案操作 =====================
ShowCtxMenu(LV, Item, IsRightClick, X, Y) {
    m := Menu()
    m.Add("開啟", (*) => OpenSelected())
    m.Add("重新命名`tF2", (*) => RenameSelected())
    m.Add()
    m.Add("複製路徑", (*) => CopyPathText())
    m.Add("複製`tCtrl+C", (*) => ClipFiles(false))
    m.Add("剪下`tCtrl+X", (*) => ClipFiles(true))
    m.Add("貼上`tCtrl+V", (*) => PasteFiles())
    m.Add()
    m.Add("刪除`tDel", (*) => DeleteSelected())
    m.Add()
    m.Add("自動調整所有欄位寬度", (*) => FitAllCols())
    m.Show()
}

CopyPathText() {
    paths := GetSelectedPaths()
    if !paths.Length
        return
    s := ""
    for p in paths
        s .= (s = "" ? "" : "`n") p
    A_Clipboard := s
    Tip(paths.Length " 個路徑已複製")
}

ClipFiles(cut) {
    paths := GetSelectedPaths()
    if !paths.Length
        return
    if PutFilesOnClipboard(paths, cut)
        Tip((cut ? "已剪下 " : "已複製 ") paths.Length " 個項目")
}

PasteFiles() {
    global gCurrentFolder
    if (PasteFilesToFolder(gCurrentFolder) > 0)
        Refresh()
}

DeleteSelected() {
    paths := GetSelectedPaths()
    if !paths.Length
        return
    if (TopMsg("確定將選取的 " paths.Length " 個項目移到資源回收筒?", "刪除", "YesNo Icon?") != "Yes")
        return
    for p in paths {
        try
            FileRecycle(p)
        catch as e
            TopMsg("刪除失敗：" p "`n" e.Message, "錯誤")
    }
    Refresh()
}

PutFilesOnClipboard(paths, cut := false) {
    CF_HDROP := 15, GHND := 0x0042
    chars := 1
    for p in paths
        chars += StrLen(p) + 1
    hMem := DllCall("GlobalAlloc", "UInt", GHND, "Ptr", 20 + chars * 2, "Ptr")
    pMem := DllCall("GlobalLock", "Ptr", hMem, "Ptr")
    NumPut("UInt", 20, pMem, 0)
    NumPut("Int", 1, pMem, 16)
    off := 20
    for p in paths {
        StrPut(p, pMem + off, StrLen(p) + 1, "UTF-16")
        off += (StrLen(p) + 1) * 2
    }
    DllCall("GlobalUnlock", "Ptr", hMem)
    if !DllCall("OpenClipboard", "Ptr", A_ScriptHwnd)
        return false
    DllCall("EmptyClipboard")
    DllCall("SetClipboardData", "UInt", CF_HDROP, "Ptr", hMem)
    cf := DllCall("RegisterClipboardFormat", "Str", "Preferred DropEffect", "UInt")
    hEff := DllCall("GlobalAlloc", "UInt", GHND, "Ptr", 4, "Ptr")
    pEff := DllCall("GlobalLock", "Ptr", hEff, "Ptr")
    NumPut("UInt", cut ? 2 : 1, pEff, 0)
    DllCall("GlobalUnlock", "Ptr", hEff)
    DllCall("SetClipboardData", "UInt", cf, "Ptr", hEff)
    DllCall("CloseClipboard")
    return true
}

PasteFilesToFolder(destDir) {
    CF_HDROP := 15
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
    move := (effect = 2), done := 0
    for f in files {
        SplitPath(f, &nm)
        dest := destDir "\" nm
        if (dest = f) {
            if move
                continue
            dest := UniqueDest(destDir, nm)
        } else if FileExist(dest)
            dest := UniqueDest(destDir, nm)
        try {
            isDir := InStr(FileExist(f), "D")
            if move
                isDir ? DirMove(f, dest, 1) : FileMove(f, dest, 1)
            else
                isDir ? DirCopy(f, dest, 1) : FileCopy(f, dest, 1)
            done++
        } catch as e {
            TopMsg("貼上失敗：" nm "`n" e.Message, "錯誤")
        }
    }
    if done
        Tip((move ? "已移動 " : "已貼上 ") done " 個項目")
    return done
}

UniqueDest(dir, name) {
    SplitPath(name, , , &ext, &base)
    i := 2
    loop {
        cand := dir "\" base " (" i ")" (ext != "" ? "." ext : "")
        if !FileExist(cand)
            return cand
        if (++i > 9999)
            return dir "\" name
    }
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

RefreshShortcutButtons() {
    global gScBtns
    if !gScBtns.Length
        return
    loop 10
        gScBtns[A_Index].Text := ShortcutLabel(A_Index)
}

; ===================== 設定視窗 =====================
ShowSettings() {
    global gGui, gHotkey, gShortcuts
    ownerOpt := (gGui ? "+Owner" gGui.Hwnd " " : "") "+AlwaysOnTop +ToolWindow"
    s := Gui(ownerOpt, "設定")
    s.SetFont("s10", "Segoe UI")

    s.AddText("xm", "啟動熱鍵（點欄位後直接按組合鍵）：")
    hk := s.AddHotkey("xm w220", gHotkey)
    auto := s.AddCheckbox("xm y+12", "開機時自動載入")
    auto.Value := IsAutoStart() ? 1 : 0

    s.AddText("xm y+14", "自訂捷徑（名稱可留空；點主視窗按鈕即切換目錄）：")
    nameEdits := [], pathEdits := []
    loop 10 {
        i := A_Index
        s.AddText("xm y+6 w46 h24 +0x200", "捷徑" i)
        ne := s.AddEdit("x+4 yp w120", gShortcuts[i].name)
        pe := s.AddEdit("x+6 yp w320", gShortcuts[i].path)
        br := s.AddButton("x+6 yp-1 w60 h24", "瀏覽")
        br.OnEvent("Click", BrowseFor.Bind(pe))
        nameEdits.Push(ne), pathEdits.Push(pe)
    }

    ok := s.AddButton("xm y+16 w90 Default", "確定")
    cancel := s.AddButton("x+10 yp w90", "取消")
    ok.OnEvent("Click", (*) => SaveSettings(s, hk, auto, nameEdits, pathEdits))
    cancel.OnEvent("Click", (*) => s.Destroy())
    s.OnEvent("Escape", (*) => s.Destroy())
    s.Show()
}

BrowseFor(pe, *) {
    sel := DirSelect(pe.Value != "" ? "*" pe.Value : "", 3, "選擇資料夾")
    if (sel != "")
        pe.Value := sel
}

SaveSettings(s, hk, auto, nameEdits, pathEdits) {
    global gHotkey, gShortcuts
    newHk := hk.Value
    if (newHk != "" && newHk != gHotkey) {
        gHotkey := newHk
        RegisterHotkey()
    }
    SetAutoStart(auto.Value)
    loop 10 {
        gShortcuts[A_Index].name := Trim(nameEdits[A_Index].Value)
        gShortcuts[A_Index].path := Trim(pathEdits[A_Index].Value)
    }
    SaveConfig()
    RefreshShortcutButtons()
    s.Destroy()
    Tip("設定已儲存")
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
