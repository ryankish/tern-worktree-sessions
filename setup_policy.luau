-- The policy describes prompts only. Choice IDs have no meaning to Tern.
local function parse(bytes)
	local ok, policy = pcall(tern.json.decode, bytes)
	if not ok then return nil, "Invalid setup JSON: " .. tostring(policy) end
	if type(policy) ~= "table" or policy.version ~= 1 or type(policy.questions) ~= "table"
		or #policy.questions == 0 then
		return nil, "Setup policy needs version 1 and at least one question"
	end
	local questions = {}
	local seen_questions = {}
	for index, question in policy.questions do
		if type(index) ~= "number" or type(question) ~= "table"
			or type(question.id) ~= "string"
			or not string.match(question.id, "^[%a_][%w_-]*$")
			or seen_questions[question.id]
			or type(question.label) ~= "string" or question.label == ""
			or type(question.choices) ~= "table" or #question.choices == 0 then
			return nil, "Invalid setup question " .. tostring(index)
		end
		seen_questions[question.id] = true
		local choices, seen_choices = {}, {}
		for choice_index, choice in question.choices do
			if type(choice_index) ~= "number" or type(choice) ~= "table"
				or type(choice.id) ~= "string"
				or not string.match(choice.id, "^[%a_][%w_-]*$")
				or seen_choices[choice.id]
				or type(choice.label) ~= "string" or choice.label == ""
				or (choice.description ~= nil and type(choice.description) ~= "string") then
				return nil, "Invalid choice in setup question " .. question.id
			end
			seen_choices[choice.id] = true
			table.insert(choices, { id = choice.id, label = choice.label,
				description = choice.description })
		end
		local default = question.default or choices[1].id
		if not seen_choices[default] then
			return nil, "Unknown default in setup question " .. question.id
		end
		if question.description ~= nil and type(question.description) ~= "string" then
			return nil, "Invalid description in setup question " .. question.id
		end
		table.insert(questions, { id = question.id, label = question.label,
			description = question.description, choices = choices, default = default })
	end
	return questions
end

return { parse = parse }
