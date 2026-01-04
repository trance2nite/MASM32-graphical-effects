.386
.model flat, stdcall
option casemap:none

include \masm32\include\windows.inc
include \masm32\include\kernel32.inc
include \masm32\include\user32.inc
include \masm32\include\gdi32.inc

includelib \masm32\lib\kernel32.lib
includelib \masm32\lib\user32.lib
includelib \masm32\lib\gdi32.lib


DlgProc             PROTO :HWND, :UINT, :WPARAM, :LPARAM
BoxWndProc          PROTO :HWND, :UINT, :WPARAM, :LPARAM
OptionsProc         PROTO :HWND, :UINT, :WPARAM, :LPARAM
GraphInit           PROTO :HWND
InitTables          PROTO
RotateImage         PROTO :HDC, :HDC, :DWORD, :DWORD
DisplayNextFrame    PROTO

.const
IDD_MAINDIALOG      equ 102
IDB_BITMAP1         equ 132
IDC_BOX             equ 1000
TIMER_ID            equ 666
IDC_QUIT            equ 5003
FP_SHIFT            equ 10          ; Fixed point shift (1024)
FP_ONE              equ 1024        ; 1.0 in fixed point

.data

    ; Bitmap dimensions
    bmpWidth        dd 159
    bmpHeight       dd 54

    ; Window dimensions
    wndWidth        dd 0
    wndHeight       dd 0

    ; Animation state
    nFrame          dd 0
    nZoom           dd 0
    nZoomDir        dd 1

    ; Effects enabled flag
    bEffects        dd 1

    ; GDI handles
    hBackDC         dd 0
    hBackBitmap     dd 0
    hBitmapDC       dd 0
    hSourceBitmap   dd 0
    hBoxWnd         dd 0
    hInstance       dd 0

    ; Original window procedure
    lpOldBoxProc    dd 0

    ; PI constant for table generation
    fPI2            REAL4 6.283185307     ; 2*PI
    fFpOne          REAL4 1024.0          ; Fixed point multiplier
    f256            REAL4 256.0           ; Table size

.data?
    ; Lookup tables
    cosTab          dd 256 dup(?)   ; Cosine table (fixed-point)
    sinTab          dd 256 dup(?)   ; Sine table (fixed-point)
    scaleTab        dd 128 dup(?)   ; Scale table (fixed-point)

    ; Rectangle for invalidation
    rcClient        RECT <>


.code

start:
    invoke GetModuleHandle, NULL
    mov hInstance, eax

    invoke DialogBoxParam, eax, IDD_MAINDIALOG, NULL, addr DlgProc, 0
    invoke ExitProcess, eax


DlgProc proc hWnd:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
    
    .if uMsg == WM_INITDIALOG
        ; Get handle to the box control
        invoke GetDlgItem, hWnd, IDC_BOX
        mov hBoxWnd, eax
        
        ; Initialize graphics
        invoke GraphInit, eax
        
        xor eax, eax
        inc eax                     ; Return TRUE
        ret

    .elseif uMsg == WM_COMMAND
        mov eax, wParam
        and eax, 0FFFFh             ; LOWORD
        
        .if eax == IDC_QUIT
            ; Clean up
            invoke KillTimer, hBoxWnd, TIMER_ID
            .if hBackDC
                invoke DeleteDC, hBackDC
            .endif
            .if hBackBitmap
                invoke DeleteObject, hBackBitmap
            .endif
            .if hBitmapDC
                invoke DeleteDC, hBitmapDC
            .endif
            .if hSourceBitmap
                invoke DeleteObject, hSourceBitmap
            .endif
            
            invoke EndDialog, hWnd, 0
        .endif
        
        xor eax, eax
        ret

    .elseif uMsg == WM_CLOSE
        invoke SendMessage, hWnd, WM_COMMAND, IDC_QUIT, 0
        xor eax, eax
        ret
    .endif

    xor eax, eax
    ret
DlgProc endp


GraphInit proc hWnd:HWND
    LOCAL hdc:HDC
    LOCAL rc:RECT

    ; Get client rectangle
    invoke GetClientRect, hWnd, addr rc
    
    mov eax, rc.right
    mov wndWidth, eax
    mov eax, rc.bottom
    mov wndHeight, eax

    ; Create back buffer
    invoke GetDC, hWnd
    mov hdc, eax
    
    invoke CreateCompatibleDC, hdc
    mov hBackDC, eax
    
    mov eax, wndWidth
    inc eax
    mov ecx, wndHeight
    inc ecx
    invoke CreateCompatibleBitmap, hdc, eax, ecx
    mov hBackBitmap, eax
    
    invoke SelectObject, hBackDC, hBackBitmap
    
    ; Clear back buffer to black
    invoke GetStockObject, BLACK_BRUSH
    invoke SelectObject, hBackDC, eax
    invoke GetStockObject, BLACK_PEN
    invoke SelectObject, hBackDC, eax
    
    invoke Rectangle, hBackDC, 0, 0, wndWidth, wndHeight
    
    invoke ReleaseDC, hWnd, hdc

    ; Load source bitmap
    invoke LoadBitmap, hInstance, IDB_BITMAP1
    mov hSourceBitmap, eax
    
    .if eax != 0
        invoke CreateCompatibleDC, hBackDC
        mov hBitmapDC, eax
        invoke SelectObject, hBitmapDC, hSourceBitmap
    .endif

    ; Initialize lookup tables
    invoke InitTables

    ; Subclass the window
    invoke SetWindowLong, hWnd, GWL_WNDPROC, addr BoxWndProc
    mov lpOldBoxProc, eax

    ; Start animation timer (30ms interval)
    invoke SetTimer, hWnd, TIMER_ID, 30, NULL
    
    mov nFrame, 0
    mov nZoom, 0
    mov nZoomDir, 1

    ret
GraphInit endp


InitTables proc
    LOCAL idx:DWORD
    LOCAL fAngle:REAL4
    LOCAL fResult:DWORD

    ; Initialize cosine and sine tables
    mov idx, 0
    .while idx < 256
        ; Calculate angle = (2*PI/256) * idx
        fld fPI2                    ; Load 2*PI
        fild idx                    ; Load index
        fmul                        ; 2*PI * idx
        fdiv f256                   ; / 256
        fst fAngle                  ; Store angle
        
        ; Calculate cos(angle) * 1024
        fcos
        fmul fFpOne                 ; * 1024
        fistp fResult               ; Store as integer
        
        mov eax, idx
        mov ecx, fResult
        mov cosTab[eax*4], ecx
        
        ; Calculate sin(angle) * 1024
        fld fAngle
        fsin
        fmul fFpOne                 ; * 1024
        fistp fResult               ; Store as integer
        
        mov eax, idx
        mov ecx, fResult
        mov sinTab[eax*4], ecx
        
        inc idx
    .endw

    ; Initialize scale table
    ; scale = 1.0/64.0, incrementing by 1.0/64.0
    ; scaleTab[i] = scale * 1024 = 16, 32, 48, ...
    
    mov idx, 0
    mov eax, 16                     ; Initial: 1024/64 = 16
    .while idx < 128
        mov ecx, idx
        mov scaleTab[ecx*4], eax
        add eax, 16                 ; Add 1024/64 = 16
        inc idx
    .endw

    ret
InitTables endp

RotateImage proc uses ebx esi edi, hBmpDC:HDC, hScrDC:HDC, angle:DWORD, zscale:DWORD
    LOCAL xPos:SDWORD
    LOCAL yPos:SDWORD
    LOCAL xT:SDWORD
    LOCAL yT:SDWORD
    LOCAL cosVal:SDWORD
    LOCAL sinVal:SDWORD
    LOCAL ySin:SDWORD
    LOCAL yCos:SDWORD
    LOCAL w2:SDWORD
    LOCAL h2:SDWORD
    LOCAL bw2:SDWORD
    LOCAL bh2:SDWORD
    LOCAL scaleFactor:SDWORD
    LOCAL destX:SDWORD
    LOCAL destY:SDWORD
    LOCAL srcX:SDWORD
    LOCAL srcY:SDWORD

    ; Clear screen to black
    invoke Rectangle, hScrDC, 0, 0, wndWidth, wndHeight

    ; Get cos and sin values (inverted angle for rotation direction)
    mov eax, 255
    sub eax, angle
    and eax, 255                    ; Wrap to 0-255
    mov ecx, cosTab[eax*4]
    mov cosVal, ecx
    mov ecx, sinTab[eax*4]
    mov sinVal, ecx

    ; Calculate half dimensions
    mov eax, wndWidth
    sar eax, 1
    mov w2, eax
    
    mov eax, wndHeight
    sar eax, 1
    mov h2, eax
    
    mov eax, bmpWidth
    sar eax, 1
    mov bw2, eax
    
    mov eax, bmpHeight
    sar eax, 1
    mov bh2, eax

    ; Get scale factor
    mov eax, zscale
    .if eax >= 128
        mov eax, 127
    .endif
    mov eax, scaleTab[eax*4]
    mov scaleFactor, eax

    ; Loop through destination pixels
    mov eax, h2
    neg eax
    mov yPos, eax                   ; yPos = -h2

@@yloop:
    mov eax, yPos
    cmp eax, h2
    jge @@done                      ; while yPos < h2

    ; Pre-calculate yPos*sinVal and yPos*cosVal for this row
    mov eax, yPos
    imul sinVal
    sar eax, FP_SHIFT
    mov ySin, eax
    
    mov eax, yPos
    imul cosVal
    sar eax, FP_SHIFT
    mov yCos, eax

    ; Inner loop: xPos
    mov eax, w2
    neg eax
    mov xPos, eax                   ; xPos = -w2

@@xloop:
    mov eax, xPos
    cmp eax, w2
    jge @@nextY                     ; while xPos < w2

    ; xT = ((xPos*cosVal - yPos*sinVal) * scale) >> 10
    mov eax, xPos
    imul cosVal
    sar eax, FP_SHIFT
    sub eax, ySin
    imul scaleFactor
    sar eax, FP_SHIFT
    mov xT, eax

    ; yT = ((xPos*sinVal + yPos*cosVal) * scale) >> 10
    mov eax, xPos
    imul sinVal
    sar eax, FP_SHIFT
    add eax, yCos
    imul scaleFactor
    sar eax, FP_SHIFT
    mov yT, eax

    ; Bounds check: if source pixel is within bitmap
    mov eax, xT
    mov ecx, bw2
    neg ecx
    cmp eax, ecx
    jle @@nextX                     ; if xT <= -bw2, skip
    
    cmp eax, bw2
    jge @@nextX                     ; if xT >= bw2, skip
    
    mov eax, yT
    mov ecx, bh2
    neg ecx
    cmp eax, ecx
    jle @@nextX                     ; if yT <= -bh2, skip
    
    cmp eax, bh2
    jge @@nextX                     ; if yT >= bh2, skip

    ; Calculate destination coordinates
    mov eax, xPos
    add eax, w2
    mov destX, eax
    
    mov eax, yPos
    add eax, h2
    mov destY, eax
    
    ; Calculate source coordinates
    mov eax, xT
    add eax, bw2
    mov srcX, eax
    
    mov eax, yT
    add eax, bh2
    mov srcY, eax
    
    ; Copy pixel
    invoke BitBlt, hScrDC, destX, destY, 1, 1, hBmpDC, srcX, srcY, SRCCOPY

@@nextX:
    inc xPos
    jmp @@xloop

@@nextY:
    inc yPos
    jmp @@yloop

@@done:
    ret
RotateImage endp

DisplayNextFrame proc
    LOCAL frameAngle:DWORD

    .if nFrame == 0
        ; First frame - just increment
        jmp @@incframe
    .endif

    ; Check zoom bounds and update direction
    mov eax, nZoom
    .if eax >= 100
        mov nZoomDir, -1
    .endif
    .if SDWORD ptr eax <= 0
        mov nZoomDir, 1
        mov nZoom, 0
    .endif

    ; Calculate angle = nFrame * 3
    mov eax, nFrame
    mov ecx, 3
    imul ecx
    and eax, 255                    ; Wrap to 0-255
    mov frameAngle, eax

    ; Render rotated image
    invoke RotateImage, hBitmapDC, hBackDC, frameAngle, nZoom

    ; Update zoom
    mov eax, nZoomDir
    shl eax, 1                      ; * 2
    add nZoom, eax

@@incframe:
    inc nFrame
    
    ; Reset frame counter to avoid overflow
    mov eax, nFrame
    .if eax > 10000
        mov nFrame, 1
    .endif
    
    ret
DisplayNextFrame endp


BoxWndProc proc hWnd:HWND, uMsg:UINT, wParam:WPARAM, lParam:LPARAM
    LOCAL hdc:HDC
    LOCAL ps:PAINTSTRUCT
    LOCAL centerX:DWORD
    LOCAL centerY:DWORD

    .if uMsg == WM_PAINT
        invoke BeginPaint, hWnd, addr ps
        mov hdc, eax

        invoke BitBlt, hdc, 0, 0, wndWidth, wndHeight, hBackDC, 0, 0, SRCCOPY
        invoke EndPaint, hWnd, addr ps
        
        xor eax, eax
        ret

    .elseif uMsg == WM_TIMER
        mov eax, wParam
        and eax, 0FFFFh
        .if eax == TIMER_ID
            .if bEffects != 0
                invoke DisplayNextFrame
            .endif
            
            invoke GetClientRect, hWnd, addr rcClient
            invoke InvalidateRect, hWnd, addr rcClient, FALSE
            invoke UpdateWindow, hWnd
        .endif
        
        xor eax, eax
        ret

    .endif

    ; Call original window procedure
    invoke CallWindowProc, lpOldBoxProc, hWnd, uMsg, wParam, lParam
    ret
BoxWndProc endp


end start
