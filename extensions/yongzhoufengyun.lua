-- 创建Package，风云再起包拓展包
-- 由**邕州风云国战俱乐部**开发制作
fengyunzaiqi = sgs.Package("fengyunzaiqi", sgs.Package_GeneralPack)

sgs.LoadTranslationTable{
    ["fengyunzaiqi"] = "风云再起",
}

-- General(Package *package, const QString &name, const QString &kingdom,int double_max_hp, bool male, bool hidden, bool never_shown)
-- General(Package 拓展包名, const QString 姓名, const QString 势力,int 血量(按阴阳鱼计算), bool 性别（true 男/false 女）, bool 是否在选将列表中隐藏, bool 是否在客户端中隐藏)
-- 创建武将 刘焉 野
liuyan = sgs.General(fengyunzaiqi, "liuyan", "careerist", 4, true)

-- 生成一张只能对自己使用的乐不思蜀技能卡
-- 原理：乐不思蜀在引擎里是延时锦囊，其 targetFilter 明确禁止指定自己
-- （standard-tricks.cpp 里 Indulgence::targetFilter 有 to_select != Self），
-- 所以只能用技能卡绕过目标限制，再在 on_effect 里把这张实体牌 takeover 成真正的
-- 【乐不思蜀】并放进自己的判定区（与引擎处理「视为延时锦囊」的做法完全一致）。
devindulgence = sgs.CreateSkillCard{
    name = "indulgence", -- 牌名
    will_throw = false, -- 使用后不弃置：子牌留在手里，由 on_effect 自行移入判定区
    can_recast = false, -- 不能重铸
    filter = function (self, targets, to_select, Self) -- 只能指定自己
        return to_select:objectName() == Self:objectName()
    end,
    feasible = function (self, targets, Self)
        -- 判定区已有【乐不思蜀】时不能再转化
        -- 注意：这里必须显式返回布尔值，返回 nil 会被当成不可用
        if Self:containsTrick("indulgence") then
            return false
        end
        return true
    end,
    on_effect = function (self, effect)
        local player = effect.to
        local room = player:getRoom()
        local subcards = self:getSubcards()
        if subcards:isEmpty() then return end

        -- 取被转化的那张实体牌，用真【乐不思蜀】覆盖它（id 不变，花色点数沿用该牌）
        local card_id = subcards:first()
        local wrapped = sgs.Sanguosha:getWrappedCard(card_id)
        local trick = sgs.Sanguosha:cloneCard("indulgence", wrapped:getSuit(), wrapped:getNumber())
        wrapped:takeOver(trick)
        room:broadcastUpdateCard(room:getPlayers(), card_id, wrapped)

        -- 移入判定区；该牌离开判定区被弃置时，引擎会自动把它还原成原来的牌
        local reason = sgs.CardMoveReason(sgs.CardMoveReason_S_REASON_USE,
            effect.from:objectName(), player:objectName(), self:getSkillName(), "")
        room:moveCardTo(wrapped, player, player, sgs.Player_PlaceDelayedTrick, reason, true)
    end,
}

-- 刘焉技能1 立牧
limu = sgs.CreateViewAsSkill{
    name = "limu",

    view_filter = function(self, selected, to_select)
        return (#selected == 0) and (to_select:getSuit() == sgs.Card_Diamond)
    end,

    view_as = function(self, cards)
        --如果没有牌被选中，那么返回空对象
        if #cards<1 then return nil end

        --每次都要新建一张技能卡：直接复用全局的 devindulgence 会不断累积上一次的子牌
        local view_as_card = devindulgence:clone()

        --将被用作视为乐不思蜀的牌都加入到乐不思蜀的subcards里
        for _,card in ipairs(cards) do
            view_as_card:addSubcard(card:getId())
        end

        --标记该乐不思蜀是由本技能生成的
        view_as_card:setSkillName(self:objectName())

        --标记生成该乐不思蜀的技能，用于亮将
        view_as_card:setShowSkill(self:objectName())

        return view_as_card
    end,


}

limu_sha = sgs.CreateTargetModSkill{
    name = "#limu_sha",
    -- 返回值是「额外的出杀次数」，最终上限 = 1 + 返回值
    residue_func = function(self, player, card)
        if player:hasSkill("limu") and card:isKindOf("Slash") and player:getJudgingArea():length()>0 then
            return player:getAttackRange()
        end
        return 0
    end,
}


-- 刘焉技能2 图射
-- 实现说明：
--   1. 「本回合未成为过牌的目标」用隐藏标记 #tushe-targeted 记录（任何角色的牌都算），
--      回合开始时（TurnStart）清空；
--   2. 「下张牌目标+1」由一个 pattern="." 的目标修改技 #tushe-target 读取 #tushe-boost 实现，
--      该标记跨回合保留，直到刘焉使用下一张牌并结算完毕（CardFinished）才移除；
--   3. 「伤害+1」在消耗 #tushe-boost 时给该牌打上 tushe-damage 标记，
--      ConfirmDamage 时对伤害来源为该牌使用者的伤害各 +1（牌结算完毕引擎会自动 clearCardFlag）。
tushe = sgs.CreateTriggerSkill{
    name = "tushe",
    frequency = sgs.Skill_Compulsory,
    events = {sgs.TurnStart, sgs.TargetConfirmed, sgs.PreCardUsed, sgs.ConfirmDamage, sgs.CardFinished},
    can_trigger = function(self, event, room, player, data)
        -- 无来源的事件（如闪电伤害）触发者为 nil，直接跳过，避免访问空对象
        if player == nil then return "", "" end

        if event == sgs.TurnStart then
            -- 新回合开始，重置「本回合是否成为过牌的目标」与「本回合是否已获得加成」
            for _, p in sgs.qlist(room:getAlivePlayers()) do
                room:setPlayerMark(p, "#tushe-targeted", 0)
                room:setPlayerMark(p, "#tushe-granted", 0)
            end
            return "", ""

        elseif event == sgs.TargetConfirmed then
            local use = data:toCardUse()
            if use.card == nil or not use.to:contains(player) then return "", "" end
            if player:getMark("#tushe-targeted") > 0 then return "", "" end

            -- 记录：该角色本回合已经成为过牌的目标（不可撤销的事实，写在 can_trigger 里）
            room:setPlayerMark(player, "#tushe-targeted", 1)

            local source = use.from
            if source and source:isAlive() and source:hasSkill(self:objectName()) then
                return self:objectName(), source:objectName()
            end
            return "", ""

        elseif event == sgs.PreCardUsed then
            local use = data:toCardUse()
            if use.card == nil then return "", "" end
            -- 延时锦囊（乐不思蜀/兵粮寸断/闪电）不结算立即效果，不算「下张牌」，不消耗加成
            if use.card:isKindOf("DelayedTrick") then return "", "" end
            if not player:isAlive() or not player:hasSkill(self:objectName()) then return "", "" end
            if player:getMark("#tushe-boost") < 1 then return "", "" end
            if use.card:hasFlag("tushe-boosted") then return "", "" end

            -- 消耗「下张牌」加成：目标+1 已在选目标阶段由 #tushe-target 生效，
            -- #tushe-boost 延到该牌结算结束（CardFinished）才移除，保证结算期间目标数校验一致
            room:setCardFlag(use.card, "tushe-boosted")
            room:setCardFlag(use.card, "tushe-damage")
            return self:objectName(), player:objectName()

        elseif event == sgs.ConfirmDamage then
            local damage = data:toDamage()
            if damage.card == nil or not damage.card:hasFlag("tushe-damage") then return "", "" end
            if damage.from == nil or damage.from ~= player or damage.transfer then return "", "" end
            if not player:isAlive() or not player:hasSkill(self:objectName()) then return "", "" end
            return self:objectName(), player:objectName()

        elseif event == sgs.CardFinished then
            -- 该牌结算结束，移除「下张牌」加成
            local use = data:toCardUse()
            if use.card ~= nil and use.card:hasFlag("tushe-boosted") then
                room:setPlayerMark(player, "#tushe-boost", 0)
            end

            -- 若所有存活角色本回合都已成为过牌的目标，则获得「下张牌目标+1且伤害+1」
            for _, owner in sgs.qlist(room:findPlayersBySkillName(self:objectName())) do
                if owner:isAlive() and owner:getMark("#tushe-granted") < 1 then
                    local all_targeted = true
                    for _, p in sgs.qlist(room:getAlivePlayers()) do
                        if p:getMark("#tushe-targeted") < 1 then
                            all_targeted = false
                            break
                        end
                    end
                    if all_targeted then
                        return self:objectName(), owner:objectName()
                    end
                end
            end
            return "", ""
        end
        return "", ""
    end,
    on_effect = function(self, event, room, player, data, who)
        if who == nil then return false end

        if event == sgs.TargetConfirmed then
            room:sendCompulsoryTriggerLog(who, self:objectName())
            if who:hasShownSkill(self:objectName()) then
                room:broadcastSkillInvoke(self:objectName(), 1, who)
            end
            who:drawCards(1, self:objectName())

        elseif event == sgs.PreCardUsed then
            room:sendCompulsoryTriggerLog(who, self:objectName())

        elseif event == sgs.ConfirmDamage then
            local damage = data:toDamage()
            damage.damage = damage.damage + 1
            data:setValue(damage)

        elseif event == sgs.CardFinished then
            room:setPlayerMark(who, "#tushe-granted", 1)
            room:setPlayerMark(who, "#tushe-boost", 1)
            room:sendCompulsoryTriggerLog(who, self:objectName())
            if who:hasShownSkill(self:objectName()) then
                room:broadcastSkillInvoke(self:objectName(), 2, who)
            end
        end
        return false
    end,
}

-- 图射的「下张牌目标+1」：pattern="." 表示对任意牌生效，
-- 实际只对「目标数可变」的牌（杀、需指定目标的单目标锦囊、铁索连环）产生效果。
tushe_target = sgs.CreateTargetModSkill{
    name = "#tushe-target",
    pattern = ".",
    extra_target_func = function(self, player, card)
        if player:getMark("#tushe-boost") > 0 then
            return 1
        end
        return 0
    end,
}

liuyan:addSkill(limu)
liuyan:addSkill(limu_sha)
liuyan:addSkill(tushe)
liuyan:addSkill(tushe_target)

sgs.insertRelatedSkills(fengyunzaiqi, "limu", "#limu_sha")
sgs.insertRelatedSkills(fengyunzaiqi, "tushe", "#tushe-target")
sgs.LoadTranslationTable{
    ["#liuyan"] = "裂土之宗",
    ["liuyan"] = "刘焉",
    ["illustrator:liuyan"] = "明暗交界",
	["designer:liuyan"] = "邕州风云俱乐部",
    ["limu"] = "立牧",
    [":limu"] = "出牌阶段，你可以将一张方块牌当作【乐不思蜀】置于你的判定区；若你的判定区有牌，出【杀】的次数上限+X(X为你的攻击范围)。",

    ["tushe"] = "图射",
    [":tushe"] = "每当你使用牌指定一名角色为目标后，若其本回合未成为过牌的目标，你摸一张牌，若所有角色本回合均成为过牌的目标，你的下张牌目标和伤害+1。",

    -- 刘焉
    ["$limu1"] = "废史立牧，可得一方安定。",
    ["$limu2"] = "米贼作乱，吾必为益州自保。",
    ["$tushe1"] = "非英杰不图？吾既谋之且射毕。",
    ["$tushe2"] = "汉室衰微，朝纲祸乱，必图后福。",
    ["~liuyan"] = "背疮难治，世子难继。",
}

--最后返回包含这个Package对象的表
return {fengyunzaiqi}