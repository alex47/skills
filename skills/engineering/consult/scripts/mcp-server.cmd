@echo off
rem Windows launcher for the consult MCP server. Hosts resolve the extensionless
rem mcp-server command to this file, which starts the PowerShell server.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0mcp-server.ps1" %*
