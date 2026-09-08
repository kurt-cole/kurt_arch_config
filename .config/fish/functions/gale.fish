function gale --description "Gale mod manager (WebKit DMABUF workaround)"
    set -x WEBKIT_DISABLE_DMABUF_RENDERER 1
    command gale $argv
end
