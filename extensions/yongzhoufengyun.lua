-- 创建Package，邕州风云拓展包
fengyun = sgs.Package("fengyun", sgs.Package_GeneralPack)

sgs.LoadTranslationTable{
    ["fengyun"] = "邕州风云",
}

-- General(Package *package, const QString &name, const QString &kingdom,int double_max_hp, bool male, bool hidden, bool never_shown)
-- General(Package 拓展包名, const QString 姓名, const QString 势力,int 血量(按阴阳鱼计算), bool 性别（true 男/false 女）, bool 是否在选将列表中隐藏, bool 是否在客户端中隐藏)
-- 创建武将 刘焉 野
liuyan = sgs.General(fengyun, "liuyan", "careerist", 4, true)
-- 刘焉技能1 立牧
limu = sgs.CreateViewAsSkill{
    name = "limu",
    events = {sgs.EventPhaseProceeding},

    view_filter = function(self, selected, to_select)
        return (#selected == 0) and (to_select:getSuit() == sgs.Card_Diamond)
    end,

    view_as = function(self, cards)
        --如果没有牌被选中，那么返回空对象
        if #cards<1 then return nil end

        local suit,number

        --如果所有被选中的牌的花色一样，那么被视为的乐不思蜀的花色也为该花色。否则，该乐不思蜀无花色。
	    --点数同理。
        for _,card in ipairs(cards) do
            if suit and (suit~=card:getSuit()) then suit=sgs.Card_NoSuit else suit=card:getSuit() end
            if number and (number~=card:getNumber()) then number=-1 else number=card:getNumber() end
	    end

        --生成一张乐不思蜀
        local view_as_card = sgs.Sanguosha:cloneCard("indulgence", suit, number)

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
    residue_func = function(self, player, card)
        if(player:hasSkill(self:objectName()) and card:isKindOf("Slash")) then
            if player:getJudgingArea():length()>0 then -- 如果判定区有牌
                return player:getAttackRange()
            end
        end
    end,
}


-- 刘焉技能2 图射
-- tushe = sgs.CreateTriggerSkill{
--     name = "tushe",
--     events = {sgs.TargetConfirmed},
-- }

liuyan:addSkill(limu)
liuyan:addSkill(limu_sha)
-- liuyan:addSkill(tushe)

sgs.insertRelatedSkills(fengyun, "limu", "#limu_sha")
sgs.LoadTranslationTable{
    ["#liuyan"] = "裂土之宗",
    ["liuyan"] = "刘焉",
    ["illustrator:liuyan"] = "明暗交界",
	["designer:liuyan"] = "丢肆",
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
return {fengyun}