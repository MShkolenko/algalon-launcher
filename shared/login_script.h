#pragma once

// One glue-screen implementation for both platforms. It fills once and never submits a login.
inline constexpr char ALGALON_LOGIN_SCRIPT[] = R"lua(
local account, password = @@ACCOUNT@@, @@PASSWORD@@
local frame = CreateFrame('Frame')
local seconds = 0
frame:SetScript('OnUpdate', function(self, dt)
    seconds = seconds + dt
    local ui = AccountLogin and AccountLogin.UI
    local a = ui and ui.AccountEditBox
    local p = ui and ui.PasswordEditBox
    if a and p and a:IsShown() and p:IsShown() then
        a:SetText(account)
        p:SetText(password)
        p:ClearFocus()
        account, password = nil, nil
        self:SetScript('OnUpdate', nil)
    elseif seconds >= 30 then
        account, password = nil, nil
        self:SetScript('OnUpdate', nil)
    end
end)
)lua";
