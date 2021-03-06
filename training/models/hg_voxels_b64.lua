paths.dofile('layers/Residual.lua')

local function hourglass(n, f, inp)
    -- Upper branch
    local up1 = inp
    for i = 1,opt.nModules do up1 = Residual(f,f)(up1) end

    -- Lower branch
    local low1 = cudnn.SpatialMaxPooling(2,2,2,2)(inp)
    for i = 1,opt.nModules do low1 = Residual(f,f)(low1) end
    local low2

    if n > 1 then low2 = hourglass(n-1,f,low1)
    else
        low2 = low1
        for i = 1,opt.nModules do low2 = Residual(f,f)(low2) end
    end

    local low3 = low2
    for i = 1,opt.nModules do low3 = Residual(f,f)(low3) end
    local up2 = nn.SpatialUpSamplingNearest(2)(low3)

    -- Bring two branches together
    return nn.CAddTable()({up1,up2})
end

local function lin(numIn,numOut,inp)
    -- Apply 1x1 convolution, stride 1, no padding
    local l = cudnn.SpatialConvolution(numIn,numOut,1,1,1,1,0,0)(inp)
    return cudnn.ReLU(true)(nn.SpatialBatchNormalization(numOut)(l))
end

local function upsampling(res)
    local upsampling = nn.Sequential()
    upsampling:add(nn.SpatialUpSamplingBilinear({oheight=res, owidth=res}))
    upsampling:add(cudnn.ReLU(true))
    upsampling:add(cudnn.SpatialConvolution(opt.nOutChannels, opt.nOutChannels, 3, 3, 1, 1, 1, 1))
    cudnn.convert(upsampling, cudnn)
    return upsampling
end

function createModel()
    local inp = nn.Identity()()

    local r4 = Residual(#opt.jointsIx*opt.depthClasses,128)(inp) -- (16 * 19) x 64 x 64
    local r5 = Residual(128,opt.nFeats)(r4)

    local out = {}
    local inter = r5

    for i = 1,opt.nStack do
        local hg = hourglass(4,opt.nFeats,inter)

        -- Residual layers at output resolution
        local ll = hg
        for j = 1,opt.nModules do ll = Residual(opt.nFeats,opt.nFeats)(ll) end
        -- Linear layer to produce first set of predictions
        ll = lin(opt.nFeats,opt.nFeats,ll)

        -- Predicted heatmaps
        local tmpOut = cudnn.SpatialConvolution(opt.nFeats,opt.nOutChannels,1,1,1,1,0,0)(ll)

        local tmpOutHigh = upsampling(opt.nVoxels)(tmpOut)
        local tmpOutSigmoid = nn.Sigmoid()(tmpOutHigh)
        -- If    intermediate supervision: add
        -- If no intermediate supervision: add if this is the last stack
        if(  opt.intsup  or  ( (i == opt.nStack) and (not opt.intsup) )  ) then
            table.insert(out,tmpOutSigmoid)
        end

        -- Add predictions back
        if i < opt.nStack then
            local ll_ = cudnn.SpatialConvolution(opt.nFeats,opt.nFeats,1,1,1,1,0,0)(ll)
            local tmpOut_ = cudnn.SpatialConvolution(opt.nOutChannels,opt.nFeats,1,1,1,1,0,0)(tmpOut)
            inter = nn.CAddTable()({inter, ll_, tmpOut_})
        end
    end

    -- Final model
    local model = nn.gModule({inp}, out)

    print('Return hg (joints3D) => voxels')
    return model
end
