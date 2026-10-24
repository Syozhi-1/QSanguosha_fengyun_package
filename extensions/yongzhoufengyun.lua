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
--   1. 「本回合是否成为过牌的目标」用无前缀标记 tushe-targeted 记录（任何角色的牌都算），
--      回合开始时（TurnStart）清空；无前缀标记不会显示在武将牌上，避免刷屏。
--   2. 「下张牌目标+1」由一个 pattern="." 的目标修改技 #tushe-target 读取可见标记 #tushe 实现，
--      #tushe 跨回合保留，直到刘焉使用下一张牌并结算完毕（CardFinished）才移除；
--      用 # 开头的名字是为了让界面显示成「图射[1]」，提示玩家手里还有一次加成。
--   3. 「伤害+1」在消耗 #tushe 时给该牌打上 tushe-damage 标记，
--      ConfirmDamage 时对伤害来源为该牌使用者的伤害各 +1（牌结算完毕引擎会自动 clearCardFlag）。
--   4. 场上没有刘焉时不记录任何「图射」标记（否则会污染别人的武将牌）。
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
                room:setPlayerMark(p, "tushe-targeted", 0)
                room:setPlayerMark(p, "tushe-granted", 0)
            end
            return "", ""

        elseif event == sgs.TargetConfirmed then
            local use = data:toCardUse()
            if use.card == nil or not use.to:contains(player) then return "", "" end

            -- 场上没有刘焉就完全不记录（否则会给无关对局的所有人打上「图射」标记）
            local owners = room:findPlayersBySkillName(self:objectName())
            if owners:isEmpty() then return "", "" end

            if player:getMark("tushe-targeted") > 0 then return "", "" end

            -- 记录：该角色本回合已经成为过牌的目标（不可撤销的事实，写在 can_trigger 里）
            room:setPlayerMark(player, "tushe-targeted", 1)

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
            if player:getMark("#tushe") < 1 then return "", "" end
            if use.card:hasFlag("tushe-boosted") then return "", "" end

            -- 消耗「下张牌」加成：目标+1 已在选目标阶段由 #tushe-target 生效，
            -- #tushe 延到该牌结算结束（CardFinished）才移除，保证结算期间目标数校验一致
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
                room:setPlayerMark(player, "#tushe", 0)
            end

            -- 若所有存活角色本回合都已成为过牌的目标，则获得「下张牌目标+1且伤害+1」
            for _, owner in sgs.qlist(room:findPlayersBySkillName(self:objectName())) do
                if owner:isAlive() and owner:getMark("tushe-granted") < 1 then
                    local all_targeted = true
                    for _, p in sgs.qlist(room:getAlivePlayers()) do
                        if p:getMark("tushe-targeted") < 1 then
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
            room:setPlayerMark(who, "tushe-granted", 1)
            room:setPlayerMark(who, "#tushe", 1)
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
        if player:getMark("#tushe") > 0 then
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

-- General(Package 拓展包名, const QString 姓名, const QString 势力,int 血量(按阴阳鱼计算), bool 性别（true 男/false 女）, bool 是否在选将列表中隐藏, bool 是否在客户端中隐藏)
-- 创建武将 曹操 魏
-- 注意：objectName 不能写 "caocao"——国战标准包已有官方曹操（objectName 就是 caocao），
-- 重名会让两个武将共用同一套技能查询、事件也会串到官方曹操身上，这里统一用 fyzq_caocao 完全解耦。
fyzq_caocao = sgs.General(fengyunzaiqi, "fyzq_caocao", "wei", 4, true)

-- ============================ 曹操 ============================

-- 魏武的第二段效果：弃置一张通过「奸雄」获得的牌，令「下一回合」出【杀】次数 +1（至多 3 次）。
-- 标记分三个：
--   fyzq-weiwu-pending  待生效的累积次数（无前缀 = 不显示），每次发动「魏武」+1，最多 3；
--   fyzq-weiwu-cur      本回合已生效、由 #fyzq-weiwu-target 读取的次数（无前缀 = 不显示）；
--   #fyzqweiwu          界面上的「魏武[x]」，= pending + cur（发动当刻就会刷新，不用等自己回合开始）。
fyzqweiwu_sync_mark = function (room, player)
    if room == nil or player == nil then return end
    local value = player:getMark("fyzq-weiwu-pending") + player:getMark("fyzq-weiwu-cur")
    if value > 3 then value = 3 end
    room:setPlayerMark(player, "#fyzqweiwu", value)
end

fyzqweiwu_add_slash = function (room, who, card)
    if room == nil or who == nil or card == nil then return end
    if not who:isAlive() or not who:hasSkill("fyzqweiwu") then return end
    if not who:inHeadSkills("fyzqweiwu") then return end
    if who:getMark("fyzq-weiwu-pending") + who:getMark("fyzq-weiwu-cur") >= 3 then return end
    -- 用 userdefine: 前缀是为了让客户端显示自定义提示语（见翻译表里的 "@define:fyzq-weiwu-discard"）
    if not room:askForSkillInvoke(who, "userdefine:fyzq-weiwu-discard", sgs.QVariant()) then return end
    room:notifySkillInvoked(who, "fyzqweiwu")
    room:broadcastSkillInvoke("fyzqweiwu", who)
    room:throwCard(card, who, who, "fyzqweiwu")
    room:addPlayerMark(who, "fyzq-weiwu-pending", 1)
    fyzqweiwu_sync_mark(room, who)
end

-- 奸雄：当你受到伤害后，你可以获得对你造成伤害的牌并摸一张牌。
fyzqjianxiong = sgs.CreateTriggerSkill{
    name = "fyzqjianxiong",
    frequency = sgs.Skill_Frequent,
    events = {sgs.Damaged},

    can_trigger = function (self, event, room, player, data)
        if player == nil or not player:isAlive() then return "", "" end
        if not player:hasSkill(self:objectName()) then return "", "" end
        local damage = data:toDamage()
        -- 伤害必须有实体牌、且这张牌还留在处理区（已经被移走的牌不能获得）
        if damage.card == nil then return "", "" end
        if room:getCardIdsOnTable(damage.card):length() == 0 then return "", "" end
        return self:objectName(), player:objectName()
    end,

    on_cost = function (self, event, room, player, data, who)
        return room:askForSkillInvoke(who, self:objectName(), data)
    end,

    on_effect = function (self, event, room, player, data, who)
        local damage = data:toDamage()
        local card = damage.card
        room:notifySkillInvoked(who, self:objectName())
        room:broadcastSkillInvoke(self:objectName(), who)
        who:obtainCard(card)
        who:drawCards(1, self:objectName())
        -- 魏武：获得这张牌后，可以弃置它换取下一回合的额外【杀】次数
        fyzqweiwu_add_slash(room, who, card)
        return false
    end,
}

-- 魏武：主将技，锁定技，你获得「清正」和「护驾」，且你死亡时，令与你势力相同的所有角色失去一点体力。
-- （清正、护驾 直接挂在这个武将上以便注册进 Engine，但两者的 can_trigger 都要求 inHeadSkills("fyzqweiwu")，
--   并用 relate_to_place="head" 让它们在副将位不显示，等价于「只有魏武在主将位才获得」。）
-- 下面只保留主将技的死亡效果与出杀次数维护。
fyzqweiwu = sgs.CreateTriggerSkill{
    name = "fyzqweiwu",
    frequency = sgs.Skill_Compulsory,
    relate_to_place = "head",   -- 主将技：副将位不显示
    events = {sgs.TurnStart, sgs.EventPhaseEnd, sgs.Death},

    can_trigger = function (self, event, room, player, data)
        if player == nil then return "", "" end

        if event == sgs.Death then
            local death = data:toDeath()
            if death.who == nil or death.who:objectName() ~= player:objectName() then return "", "" end
            if not player:hasSkill(self:objectName()) then return "", "" end
            if not player:inHeadSkills(self:objectName()) then return "", "" end
            return self:objectName(), player:objectName()
        end

        if not player:isAlive() or not player:hasSkill(self:objectName()) then return "", "" end
        if room:getCurrent() == nil or room:getCurrent():objectName() ~= player:objectName() then return "", "" end

        if event == sgs.TurnStart then
            -- 把「上一回合获得的额外次数」转入本回合
            local pending = player:getMark("fyzq-weiwu-pending")
            if pending > 3 then pending = 3 end
            room:setPlayerMark(player, "fyzq-weiwu-cur", pending)
            room:setPlayerMark(player, "fyzq-weiwu-pending", 0)
            fyzqweiwu_sync_mark(room, player)
            return "", ""
        end

        if event == sgs.EventPhaseEnd then
            if player:getPhase() == sgs.Player_Finish then
                room:setPlayerMark(player, "fyzq-weiwu-cur", 0)
                fyzqweiwu_sync_mark(room, player)
            end
            return "", ""
        end

        return "", ""
    end,

    on_effect = function (self, event, room, player, data, who)
        local kingdom = who:getKingdom()
        room:sendCompulsoryTriggerLog(who, self:objectName())
        room:broadcastSkillInvoke(self:objectName(), who)
        for _, p in sgs.qlist(room:getAlivePlayers()) do
            if p:objectName() ~= who:objectName() and p:getKingdom() == kingdom then
                room:loseHp(p, 1)
            end
        end
        return false
    end,
}

-- 清正：原设计还有「你的【六龙骖驾】只占用一个坐骑栏、且可以让其他坐骑牌进入你的装备区」两句，
-- 这两条在本引擎做不到：六龙骖驾的卡与技能（SixDragons / SixDragonsSkill）编译在 QSanguosha.exe 里，
-- 装上它之后「其他坐骑牌不可用」的判定发生在 C++ 侧（Engine::isProhibited 直接遍历编译进引擎的
-- ProhibitSkill，见 src\core\engine.cpp:1054；Lua 的 CreateProhibitSkill 只能增加禁止、无法解除），
-- 而拓展包不允许改原游戏文件，所以按需求去掉这两句，只保留「【六龙骖驾】离开你的装备区时，你回复一点体力」。
--
-- 判定方式不再看 CardsMoveOneTime 的 from_places（不同版本的 QList<Player::Place>
-- 在 Lua 里表现不一致，实测会漏触发），改成每次牌移动后比较「装备区里有没有六龙骖驾」的
-- 前后状态：上次有、这次没有 => 它离开了你的装备区。这样无论被弃置、被顺走、被换装、
-- 被移动、被消灭都能触发，而且不依赖移动事件的字段细节。
fyzqqingzheng_has_sixdragons = function (player)
    if player == nil then return false end
    for _, c in sgs.qlist(player:getEquips()) do
        if c:isKindOf("SixDragons") then return true end
    end
    return false
end

fyzqqingzheng = sgs.CreateTriggerSkill{
    name = "fyzqqingzheng",
    frequency = sgs.Skill_Compulsory,
    relate_to_place = "head",   -- 由主将技「魏武」授予，副将位不显示
    events = {sgs.CardsMoveOneTime, sgs.TurnStart},

    can_trigger = function (self, event, room, player, data)
        if player == nil or not player:isAlive() then return "", "" end
        if not player:hasSkill(self:objectName()) then return "", "" end
        -- 「魏武」是主将技：只有魏武在主将位时，它授予的技能才生效
        if not player:inHeadSkills("fyzqweiwu") then return "", "" end

        local now_has = fyzqqingzheng_has_sixdragons(player) and 1 or 0
        local before = player:getMark("fyzq-qingzheng-equipped")
        -- 同步状态（can_trigger 里的副作用必须可重复执行，这里只是记录事实）
        room:setPlayerMark(player, "fyzq-qingzheng-equipped", now_has)

        if before >= 1 and now_has == 0 then
            return self:objectName(), player:objectName()
        end
        return "", ""
    end,

    on_effect = function (self, event, room, player, data, who)
        if who:isAlive() then
            room:sendCompulsoryTriggerLog(who, self:objectName())
            room:broadcastSkillInvoke(self:objectName(), who)
            local recover = sgs.RecoverStruct()
            recover.who = who
            recover.recover = 1
            room:recover(who, recover)
        end
        return false
    end,
}

-- 可作为「护驾」转移目标的角色：与你势力相同的其他存活角色，且本轮还没被选过
fyzqhujia_targets = function (room, player)
    local targets = sgs.SPlayerList()
    for _, p in sgs.qlist(room:getOtherPlayers(player)) do
        if p:isAlive() and p:isFriendWith(player) and p:getMark("fyzq-hujia-used") == 0 then
            targets:append(p)
        end
    end
    return targets
end

-- 护驾：每轮每名与你势力相同的其他角色限一次，当你受到伤害时，你可将此伤害转移给一名与你势力相同的其他角色，
-- 然后你可以如你受伤般发动「奸雄」。
-- 「每轮每名」用每个角色自己的回合边界实现：该角色回合开始时清空自己的 fyzq-hujia-used。
fyzqhujia = sgs.CreateTriggerSkill{
    name = "fyzqhujia",
    frequency = sgs.Skill_Frequent,
    relate_to_place = "head",   -- 由主将技「魏武」授予，副将位不显示
    events = {sgs.DamageInflicted, sgs.TurnStart},

    can_trigger = function (self, event, room, player, data)
        if player == nil then return "", "" end

        if event == sgs.TurnStart then
            -- 轮到谁，谁就进入新的一轮，可以重新被选为转移目标
            room:setPlayerMark(player, "fyzq-hujia-used", 0)
            return "", ""
        end

        if not player:isAlive() or not player:hasSkill(self:objectName()) then return "", "" end
        if not player:inHeadSkills("fyzqweiwu") then return "", "" end
        local damage = data:toDamage()
        if damage.to == nil or damage.to:objectName() ~= player:objectName() then return "", "" end
        if damage.transfer then return "", "" end
        if fyzqhujia_targets(room, player):length() == 0 then return "", "" end
        return self:objectName(), player:objectName()
    end,

    on_cost = function (self, event, room, player, data, who)
        return room:askForSkillInvoke(who, self:objectName(), data)
    end,

    on_effect = function (self, event, room, player, data, who)
        local targets = fyzqhujia_targets(room, who)
        if targets:length() == 0 then return false end
        local damage = data:toDamage()
        local target = room:askForPlayerChosen(who, targets, self:objectName(), "@fyzq-hujia", false, true)
        if target == nil then return false end

        -- askForPlayerChosen 第 6 参 notify_skill=true 已经发过技能发动提示，这里只播语音
        room:broadcastSkillInvoke(self:objectName(), who)
        room:setPlayerMark(target, "fyzq-hujia-used", 1)

        -- 转移伤害：把修改后的 DamageStruct 塞回 data，并写进受伤者的 TransferDamage 标记供引擎读取
        damage.transfer = true
        damage.to = target
        damage.transfer_reason = self:objectName()
        data:setValue(damage)
        who:setTag("TransferDamage", data)

        -- 然后可以「如你受伤般」发动奸雄（传原始 DamageStruct，客户端会显示标准的「是否发动【奸雄】？」）
        local card = damage.card
        if who:hasSkill("fyzqjianxiong") and card ~= nil then
            if room:getCardIdsOnTable(card):length() > 0 then
                if room:askForSkillInvoke(who, "fyzqjianxiong", data) then
                    room:notifySkillInvoked(who, "fyzqjianxiong")
                    room:broadcastSkillInvoke("fyzqjianxiong", who)
                    who:obtainCard(card)
                    who:drawCards(1, "fyzqjianxiong")
                    fyzqweiwu_add_slash(room, who, card)
                end
            end
        end

        return true
    end,
}

-- AI 回应：奸雄总是值得发动；「魏武」丢弃刚获得的牌换下回合多出一刀，也默认发动
-- 注意 SmartAI:askForSkillInvoke 会先把技能名里的 "-" 换成 "_"，所以这里也要用下划线
if sgs.ai_skill_invoke then
    sgs.ai_skill_invoke["fyzqjianxiong"] = function(self) return true end
    sgs.ai_skill_invoke["userdefine:fyzq_weiwu_discard"] = function(self) return true end
end

-- #fyzq-weiwu-target：【杀】的次数上限 + 魏武累积的额外次数
fyzqweiwu_target = sgs.CreateTargetModSkill{
    name = "#fyzq-weiwu-target",
    pattern = "Slash",
    residue_func = function (self, player, card)
        if player ~= nil and player:hasSkill("fyzqweiwu") and player:inHeadSkills("fyzqweiwu") then
            -- 只读「本回合已生效」的份量；#fyzqweiwu 是给界面看的合计值，不能拿来当次数用
            return player:getMark("fyzq-weiwu-cur")
        end
        return 0
    end,
}

fyzq_caocao:addSkill(fyzqjianxiong)
fyzq_caocao:addSkill(fyzqweiwu)
fyzq_caocao:addSkill(fyzqqingzheng)
fyzq_caocao:addSkill(fyzqhujia)
fyzq_caocao:addSkill(fyzqweiwu_target)

sgs.insertRelatedSkills(fengyunzaiqi, "fyzqweiwu", "#fyzq-weiwu-target")

-- 珠联璧合：卞夫人、典韦、许褚（objectName 分别为 bianhuanghou / dianwei / xuchu）
-- 引擎用 General::isCompanionWith 判断，双向任一方向登记即可
fyzq_caocao:addCompanion("bianhuanghou")
fyzq_caocao:addCompanion("dianwei")
fyzq_caocao:addCompanion("xuchu")

sgs.LoadTranslationTable{
    ["#fyzq_caocao"] = "魏武帝",
    ["fyzq_caocao"] = "曹操",
    ["illustrator:fyzq_caocao"] = "M云涯",
    ["designer:fyzq_caocao"] = "邕州风云俱乐部",
    ["@fyzq-hujia"] = "你可以将此次伤害转移给一名与你势力相同的角色",
    -- askForSkillInvoke 传入 "userdefine:XX" 时，客户端取 translate("@define:XX") 作为提示语
    ["@define:fyzq-weiwu-discard"] = "是否发动“魏武”丢弃“奸雄”获得的牌？",

    ["fyzqjianxiong"] = "奸雄",
    [":fyzqjianxiong"] = "当你受到伤害后，你可以获得对你造成伤害的牌并摸一张牌。",

    ["fyzqweiwu"] = "魏武",
    [":fyzqweiwu"] = "主将技，锁定技，你获得“清正”和“护驾”，且你死亡时，令与你势力相同的所有角色失去一点体力。当你发动“奸雄”获得一张牌时，你可以弃置此牌，令你下一回合使用【杀】的次数+1（至多加至3次）。",

    ["fyzqqingzheng"] = "清正",
    [":fyzqqingzheng"] = "锁定技，当你的【六龙骖驾】离开你的装备区时，你回复一点体力。",

    ["fyzqhujia"] = "护驾",
    [":fyzqhujia"] = "每轮每名与你势力相同的其他角色限一次，当你受到伤害时，你可将此伤害转移给一名与你势力相同的其他角色，然后你可以如你受伤般发动“奸雄”。",

    -- 曹操
    ["$fyzqjianxiong1"] = "夫英雄者，胸怀大志，腹有良谋！",
    ["$fyzqjianxiong2"] = "燕雀安知鸿鹄之志！",
    ["$fyzqweiwu1"] = "大忠似奸，留一世功名，前人赞，今人叹，后人羡！",
    ["$fyzqweiwu2"] = "乱世称雄，立一方基业，屯万兵，聚百将，拥千城！",
    ["$fyzqqingzheng1"] = "纵横驰骋，逐鹿称雄。",
    ["$fyzqqingzheng2"] = "严行正法，奸佞不敢前。",
    ["$fyzqhujia1"] = "良将辅佐，山河常青。",
    ["$fyzqhujia2"] = "吾有良将在侧，有何惧怕。",
    ["~fyzq_caocao"] = "雪鬓霜鬟，大业未完。",
}

--最后返回包含这个Package对象的表
return {fengyunzaiqi}