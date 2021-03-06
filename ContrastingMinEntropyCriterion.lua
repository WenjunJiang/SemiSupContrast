require 'nn'
local ContrastingMinEntropyCriterion, parent = torch.class('nn.ContrastingMinEntropyCriterion', 'nn.Criterion')
function ContrastingMinEntropyCriterion:__init(dist)
  parent.__init(self)
  self.dist = dist or 2
  self.batchSize = 1
  self.LogSoftMax = nn.LogSoftMax()
  self.target = torch.Tensor()
  self.buffer = torch.Tensor()
  self.NLL = nn.ClassNLLCriterion()
  self.entropy = nn.Sequential()
  self.entropy:add(nn.ConcatTable():add(nn.Exp()):add(nn.Identity()))
  self.entropy:add(nn.CMulTable())
  self.entropy:add(nn.Sum(2))
  self.entropy:add(nn.MulConstant(-1))
end

function ContrastingMinEntropyCriterion:__rebuildModule()
  local main = nn.Sequential()
  main:add(nn.Replicate(self.num, 2))
  main:add(nn.Contiguous())
  main:add(nn.View(self.batchSize*self.num,-1))

  local cmp = nn.Sequential()
  cmp:add(nn.Replicate(self.batchSize, 1))
  cmp:add(nn.Contiguous())
  cmp:add(nn.View(self.batchSize*self.num,-1))

  self.module = nn.Sequential()
  self.module:add(nn.ParallelTable():add(main):add(cmp))

  if torch.type(self.dist) == 'number' then
    self.module:add(nn.PairwiseDistance(self.dist))
    self.module:add(nn.MulConstant(-1, false))
  elseif self.dist == 'dot' then
    self.module:add(nn.DotProduct())
  elseif self.dist == 'cosine' then
    self.module:add(nn.CosineDistance())
  elseif self.dist == 'kl' then
    require 'KLDistance'
    self.module:add(nn.KLDistance())
  elseif self.dist == 'norm' then
    local NormalizedDistance = require 'NormalizedDistance'
    self.module:add(NormalizedDistance)
  end
  self.module:add(nn.View(self.batchSize, self.num))
  self.module:add(nn.LogSoftMax())

end

function ContrastingMinEntropyCriterion:updateOutput(input, target)
  if self.num ~= input[2]:size(1) or self.batchSize ~= input[1]:size(1) then
    self.batchSize = input[1]:size(1)
    self.num = input[2]:size(1)
    self:__rebuildModule()
    self.module:type(input[1]:type())
  end

  local out = self.module:updateOutput(input)


  self.output = self.NLL:updateOutput(out:sub(-self.num,-1), target:sub(-self.num,-1)) + self.entropy:forward(out:sub(1,self.batchSize - self.num)):mean()
  return self.output, self.module.output
end

function ContrastingMinEntropyCriterion:updateGradInput(input, target)
  local gradNLL = self.NLL:updateGradInput(self.module.output:sub(-self.num,-1), target:sub(-self.num,-1))
  self.target:resizeAs(self.entropy.output):fill(1)
  self.entropy:backward(self.module.output:sub(1,self.batchSize - self.num), self.target)
  self.buffer:resizeAs(self.module.output)
  self.buffer:sub(-self.num,-1):copy(gradNLL)
  self.buffer:sub(1,self.batchSize - self.num):copy(self.entropy.gradInput):div(self.batchSize - self.num)

  self.gradInput = self.module:updateGradInput(input, self.buffer)
  return self.gradInput
end
