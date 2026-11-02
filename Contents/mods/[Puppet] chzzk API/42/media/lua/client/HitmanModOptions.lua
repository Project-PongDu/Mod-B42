local config = {
    keyBind   = nil,
    checkBox  = nil,
    textEntry = nil,
    multiBox  = nil,
    comboBox  = nil,
    colorPick = nil,
    slider    = nil,
    button    = nil
}

local options = PZAPI.ModOptions:create("Hitmans", getText("UI_optionscreen_binding_Hitmans"))
options:addTitle("Hitmans")
config.keyBind = options:addKeyBind("POSTS", getText("UI_optionscreen_binding_POSTS"), Keyboard.KEY_G, getText("UI_optionscreen_binding_POSTS"))
