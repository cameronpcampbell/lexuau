local lexuau = require("@src")

local lexer = lexuau.new({
    subpatterns = {
        numsect = "_*[\\d]+_*",
        num = "((?&numsect)+\\.)?(?&numsect)+|\\.(?&numsect)"
    },

    patterns = {
        ident = "[a-zA-Z_-]+",
        number = "(?&num)"
    }
})
