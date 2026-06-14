;; extends

; Color block-level HTML comments (<!-- ... -->) as comments
((html_block) @comment
  (#lua-match? @comment "^<!%-%-"))
