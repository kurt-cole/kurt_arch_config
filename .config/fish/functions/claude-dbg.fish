function claude-dbg --description 'claude with the x64dbg MCP server loaded'
    claude --mcp-config=$HOME/.config/claude-mcp/x64dbg.json $argv
end
