    # 关键：本文件有 BOM，但 helper.ps1 没有，Windows PowerShell 5.1 会按 GBK 去读它，
    # 中文注释的字节会把后面的 ASCII 标点吞掉 → 解析器看到"意外的 }"。
    $env:GP_NO_STDIO_LOOP = '1'
    Write-Output ("A=[" + $env:GP_NO_STDIO_LOOP + "]")
