module vulkan_setup;

import font.atlas : GlyphAtlas;

import erupted;
import erupted.vulkan_lib_loader : loadGlobalLevelFunctions;
import vk_platform :
    wl_display, wl_surface,
    VkWaylandSurfaceCreateInfoKHR,
    VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
    vkCreateWaylandSurfaceKHR,
    loadInstanceLevelFunctionsWithPlatform,
    loadDeviceLevelFunctionsWithPlatform;
import wayland.client : WlDisplay, WlSurface;

import std.algorithm : min, max;
import std.exception : enforce;
import std.conv : to;

// ---------------------------------------------------------------------------

struct GlyphInstance {
    float[4] posRect;  // x, y, w, h (NDC)
    float[4] uvRect;   // u0, v0, u1, v1
    float[4] color;    // RGBA
}
static assert(GlyphInstance.sizeof == 48);

// ---------------------------------------------------------------------------

struct RectInstance {
    float[4] rect;         // x, y, width, height (NDC)
    float[4] color;        // RGBA
    float    cornerRadius;
    float[3] _pad;
}
static assert(RectInstance.sizeof == 48);

// ---------------------------------------------------------------------------

private void enforceVK(VkResult r, string msg = "Vulkan error")
{
    if (r != VK_SUCCESS)
        throw new Exception(msg ~ ": " ~ r.to!string);
}

// ---------------------------------------------------------------------------

class VulkanSetup
{
    enum MAX_FRAMES = 2;
    enum MAX_RECTS  = 4096;

    // Vulkan handles
    VkInstance       instance;
    VkSurfaceKHR     surface;
    VkPhysicalDevice physDevice;
    VkDevice         device;
    VkQueue          graphicsQueue;
    VkQueue          presentQueue;
    uint             graphicsFamily;
    uint             presentFamily;

    // Swapchain
    VkSwapchainKHR  swapchain;
    VkImage[]       swapImages;
    VkImageView[]   swapImageViews;
    VkFormat        swapFormat;
    VkExtent2D      swapExtent;

    // Render pass + framebuffers
    VkRenderPass    renderPass;
    VkFramebuffer[] framebuffers;

    // Commands
    VkCommandPool     cmdPool;
    VkCommandBuffer[] cmdBuffers;

    // Sync
    VkSemaphore[MAX_FRAMES] imageAvailable;
    VkSemaphore[MAX_FRAMES] renderFinished;
    VkFence    [MAX_FRAMES] inFlight;
    uint currentFrame;

    // Rect pipeline
    VkDescriptorSetLayout          descSetLayout;
    VkPipelineLayout               pipelineLayout;
    VkPipeline                     rectPipeline;
    VkBuffer      [MAX_FRAMES]     ssboBuffer;
    VkDeviceMemory[MAX_FRAMES]     ssboMemory;
    void*         [MAX_FRAMES]     ssboBufMapped;
    VkDescriptorPool               descPool;
    VkDescriptorSet[MAX_FRAMES]    descSets;

    // Rect data — set from outside before renderFrame
    RectInstance[] rects;

    enum MAX_GLYPHS = 4096;

    VkDescriptorSetLayout          glyphDescSetLayout;
    VkPipelineLayout               glyphPipelineLayout;
    VkPipeline                     glyphPipeline;
    VkBuffer      [MAX_FRAMES]     glyphSsboBuffer;
    VkDeviceMemory[MAX_FRAMES]     glyphSsboMemory;
    void*         [MAX_FRAMES]     glyphSsboBufMapped;
    VkDescriptorPool               glyphDescPool;
    VkDescriptorSet[MAX_FRAMES]    glyphDescSets;

    // Atlas texture
    VkImage        atlasImage;
    VkImageView    atlasImageView;
    VkDeviceMemory atlasMemory;
    VkSampler      atlasSampler;

    // Glyph data — set from outside before renderFrame
    GlyphInstance[] glyphs;

    uint width, height;
    bool needsResize;

    // -------------------------------------------------------------------

    this(WlDisplay wlDisplay, WlSurface wlSurface, uint w, uint h)
    {
        width = w; height = h;
        enforce(loadGlobalLevelFunctions(), "Failed to load Vulkan");
        createInstance();
        createSurface(wlDisplay, wlSurface);
        pickPhysicalDevice();
        createDevice();
        createSwapchain();
        createRenderPass();
        createFramebuffers();
        createCommandPool();
        allocCommandBuffers();
        createSyncObjects();
        createDescSetLayout();
        createSsboBuffers();
        createDescriptors();
        createRectPipeline();
        createGlyphDescSetLayout();
        createGlyphSsboBuffers();
        createGlyphDescriptors();
        createGlyphPipeline();
    }

    // -------------------------------------------------------------------

    private void createInstance()
    {
        VkApplicationInfo appInfo = {
            sType:              VK_STRUCTURE_TYPE_APPLICATION_INFO,
            pApplicationName:   "lowlayergui",
            applicationVersion: VK_MAKE_API_VERSION(0, 1, 0, 0),
            apiVersion:         VK_API_VERSION_1_1,
        };

        const(char)*[] exts = [
            VK_KHR_SURFACE_EXTENSION_NAME,
            VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        ];

        VkInstanceCreateInfo info = {
            sType:                   VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            pApplicationInfo:        &appInfo,
            enabledExtensionCount:   cast(uint) exts.length,
            ppEnabledExtensionNames: exts.ptr,
        };
        vkCreateInstance(&info, null, &instance).enforceVK("vkCreateInstance");
        loadInstanceLevelFunctionsWithPlatform(instance);
    }

    private void createSurface(WlDisplay wlDisplay, WlSurface wlSurface)
    {
        VkWaylandSurfaceCreateInfoKHR info = {
            sType:   VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            display: wlDisplay.native,
            surface: wlSurface.proxy,
        };
        vkCreateWaylandSurfaceKHR(instance, &info, null, &surface)
            .enforceVK("vkCreateWaylandSurfaceKHR");
    }

    private void pickPhysicalDevice()
    {
        uint count;
        vkEnumeratePhysicalDevices(instance, &count, null);
        enforce(count > 0, "No Vulkan physical devices found");

        auto devices = new VkPhysicalDevice[](count);
        vkEnumeratePhysicalDevices(instance, &count, devices.ptr);

        foreach (pd; devices)
        {
            if (queryQueueFamilies(pd))
            {
                physDevice = pd;
                return;
            }
        }
        throw new Exception("No suitable Vulkan physical device");
    }

    private bool queryQueueFamilies(VkPhysicalDevice pd)
    {
        uint count;
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, null);
        auto props = new VkQueueFamilyProperties[](count);
        vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, props.ptr);

        bool hasGraphics, hasPresent;
        foreach (i, ref p; props)
        {
            if (p.queueFlags & VK_QUEUE_GRAPHICS_BIT)
            {
                graphicsFamily = cast(uint) i;
                hasGraphics    = true;
            }
            VkBool32 presentSupport;
            vkGetPhysicalDeviceSurfaceSupportKHR(pd, cast(uint) i, surface, &presentSupport);
            if (presentSupport)
            {
                presentFamily = cast(uint) i;
                hasPresent    = true;
            }
            if (hasGraphics && hasPresent) return true;
        }
        return false;
    }

    private void createDevice()
    {
        import std.algorithm : uniq, sort;

        float priority = 1.0f;
        VkDeviceQueueCreateInfo[] queueInfos;

        uint[] families = [graphicsFamily, presentFamily];
        sort(families);
        foreach (f; families.uniq())
        {
            VkDeviceQueueCreateInfo qi = {
                sType:            VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex: f,
                queueCount:       1,
                pQueuePriorities: &priority,
            };
            queueInfos ~= qi;
        }

        const(char)*[] devExts = [VK_KHR_SWAPCHAIN_EXTENSION_NAME];

        VkDeviceCreateInfo info = {
            sType:                   VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            queueCreateInfoCount:    cast(uint) queueInfos.length,
            pQueueCreateInfos:       queueInfos.ptr,
            enabledExtensionCount:   cast(uint) devExts.length,
            ppEnabledExtensionNames: devExts.ptr,
        };

        vkCreateDevice(physDevice, &info, null, &device).enforceVK("vkCreateDevice");
        loadDeviceLevelFunctionsWithPlatform(device);

        vkGetDeviceQueue(device, graphicsFamily, 0, &graphicsQueue);
        vkGetDeviceQueue(device, presentFamily,  0, &presentQueue);
    }

    private void createSwapchain()
    {
        VkSurfaceCapabilitiesKHR caps;
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physDevice, surface, &caps);

        // フォーマット選択: sRGB 優先
        uint fmtCount;
        vkGetPhysicalDeviceSurfaceFormatsKHR(physDevice, surface, &fmtCount, null);
        auto formats = new VkSurfaceFormatKHR[](fmtCount);
        vkGetPhysicalDeviceSurfaceFormatsKHR(physDevice, surface, &fmtCount, formats.ptr);

        VkSurfaceFormatKHR fmt = formats[0];
        foreach (f; formats)
        {
            if (f.format == VK_FORMAT_B8G8R8A8_SRGB
             && f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            { fmt = f; break; }
        }
        swapFormat = fmt.format;

        // Extent
        if (caps.currentExtent.width != uint.max)
        {
            swapExtent = caps.currentExtent;
        }
        else
        {
            swapExtent.width  = min(max(width,  caps.minImageExtent.width),  caps.maxImageExtent.width);
            swapExtent.height = min(max(height, caps.minImageExtent.height), caps.maxImageExtent.height);
        }

        uint imgCount = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) imgCount = min(imgCount, caps.maxImageCount);

        VkSwapchainCreateInfoKHR info = {
            sType:            VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            surface:          surface,
            minImageCount:    imgCount,
            imageFormat:      swapFormat,
            imageColorSpace:  fmt.colorSpace,
            imageExtent:      swapExtent,
            imageArrayLayers: 1,
            imageUsage:       VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            preTransform:     caps.currentTransform,
            compositeAlpha:   VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            presentMode:      VK_PRESENT_MODE_FIFO_KHR,
            clipped:          VK_TRUE,
        };

        if (graphicsFamily != presentFamily)
        {
            uint[] idx = [graphicsFamily, presentFamily];
            info.imageSharingMode      = VK_SHARING_MODE_CONCURRENT;
            info.queueFamilyIndexCount = 2;
            info.pQueueFamilyIndices   = idx.ptr;
        }
        else
        {
            info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
        }

        vkCreateSwapchainKHR(device, &info, null, &swapchain).enforceVK("vkCreateSwapchainKHR");

        uint n;
        vkGetSwapchainImagesKHR(device, swapchain, &n, null);
        swapImages.length = n;
        vkGetSwapchainImagesKHR(device, swapchain, &n, swapImages.ptr);

        swapImageViews.length = n;
        foreach (i, img; swapImages)
        {
            VkImageViewCreateInfo ivInfo = {
                sType:    VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                image:    img,
                viewType: VK_IMAGE_VIEW_TYPE_2D,
                format:   swapFormat,
                components: VkComponentMapping(
                    VK_COMPONENT_SWIZZLE_IDENTITY,
                    VK_COMPONENT_SWIZZLE_IDENTITY,
                    VK_COMPONENT_SWIZZLE_IDENTITY,
                    VK_COMPONENT_SWIZZLE_IDENTITY,
                ),
                subresourceRange: VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1),
            };
            vkCreateImageView(device, &ivInfo, null, &swapImageViews[i]).enforceVK;
        }
    }

    private void createRenderPass()
    {
        VkAttachmentDescription colorAttachment = {
            format:         swapFormat,
            samples:        VK_SAMPLE_COUNT_1_BIT,
            loadOp:         VK_ATTACHMENT_LOAD_OP_CLEAR,
            storeOp:        VK_ATTACHMENT_STORE_OP_STORE,
            stencilLoadOp:  VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
            initialLayout:  VK_IMAGE_LAYOUT_UNDEFINED,
            finalLayout:    VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        VkAttachmentReference colorRef = {
            attachment: 0,
            layout:     VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        VkSubpassDescription subpass = {
            pipelineBindPoint:    VK_PIPELINE_BIND_POINT_GRAPHICS,
            colorAttachmentCount: 1,
            pColorAttachments:    &colorRef,
        };

        VkSubpassDependency dep = {
            srcSubpass:    VK_SUBPASS_EXTERNAL,
            dstSubpass:    0,
            srcStageMask:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            srcAccessMask: 0,
            dstStageMask:  VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            dstAccessMask: VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        VkRenderPassCreateInfo info = {
            sType:           VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            attachmentCount: 1,
            pAttachments:    &colorAttachment,
            subpassCount:    1,
            pSubpasses:      &subpass,
            dependencyCount: 1,
            pDependencies:   &dep,
        };

        vkCreateRenderPass(device, &info, null, &renderPass).enforceVK("vkCreateRenderPass");
    }

    private void createFramebuffers()
    {
        framebuffers.length = swapImageViews.length;
        foreach (i; 0 .. swapImageViews.length)
        {
            VkFramebufferCreateInfo info = {
                sType:           VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                renderPass:      renderPass,
                attachmentCount: 1,
                pAttachments:    &swapImageViews[i],
                width:           swapExtent.width,
                height:          swapExtent.height,
                layers:          1,
            };
            vkCreateFramebuffer(device, &info, null, &framebuffers[i]).enforceVK;
        }
    }

    private void createCommandPool()
    {
        VkCommandPoolCreateInfo info = {
            sType:            VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            flags:            VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            queueFamilyIndex: graphicsFamily,
        };
        vkCreateCommandPool(device, &info, null, &cmdPool).enforceVK("vkCreateCommandPool");
    }

    private void allocCommandBuffers()
    {
        cmdBuffers.length = framebuffers.length;
        VkCommandBufferAllocateInfo info = {
            sType:              VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool:        cmdPool,
            level:              VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            commandBufferCount: cast(uint) cmdBuffers.length,
        };
        vkAllocateCommandBuffers(device, &info, cmdBuffers.ptr).enforceVK;
    }

    private void createSyncObjects()
    {
        VkSemaphoreCreateInfo semInfo  = { sType: VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        VkFenceCreateInfo     fenceInfo = {
            sType: VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            flags: VK_FENCE_CREATE_SIGNALED_BIT,
        };
        foreach (i; 0 .. MAX_FRAMES)
        {
            vkCreateSemaphore(device, &semInfo,   null, &imageAvailable[i]).enforceVK;
            vkCreateSemaphore(device, &semInfo,   null, &renderFinished[i]).enforceVK;
            vkCreateFence    (device, &fenceInfo, null, &inFlight[i]).enforceVK;
        }
    }

    // -------------------------------------------------------------------
    // rect instancing pipeline
    // -------------------------------------------------------------------

    private uint findMemoryType(uint typeFilter, VkMemoryPropertyFlags props)
    {
        VkPhysicalDeviceMemoryProperties memProps;
        vkGetPhysicalDeviceMemoryProperties(physDevice, &memProps);
        foreach (i; 0 .. memProps.memoryTypeCount)
        {
            if ((typeFilter & (1u << i)) &&
                (memProps.memoryTypes[i].propertyFlags & props) == props)
                return i;
        }
        throw new Exception("Failed to find suitable memory type");
    }

    private VkShaderModule createShaderModule(const(ubyte)[] code)
    {
        VkShaderModuleCreateInfo info = {
            sType:    VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            codeSize: code.length,
            pCode:    cast(const uint*) code.ptr,
        };
        VkShaderModule mod;
        vkCreateShaderModule(device, &info, null, &mod).enforceVK("vkCreateShaderModule");
        return mod;
    }

    private void createDescSetLayout()
    {
        VkDescriptorSetLayoutBinding binding = {
            binding:         0,
            descriptorType:  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            descriptorCount: 1,
            stageFlags:      VK_SHADER_STAGE_VERTEX_BIT,
        };
        VkDescriptorSetLayoutCreateInfo info = {
            sType:        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            bindingCount: 1,
            pBindings:    &binding,
        };
        vkCreateDescriptorSetLayout(device, &info, null, &descSetLayout)
            .enforceVK("vkCreateDescriptorSetLayout");
    }

    private void createSsboBuffers()
    {
        VkDeviceSize bufSize = RectInstance.sizeof * MAX_RECTS;
        foreach (i; 0 .. MAX_FRAMES)
        {
            VkBufferCreateInfo bInfo = {
                sType:       VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                size:        bufSize,
                usage:       VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            };
            vkCreateBuffer(device, &bInfo, null, &ssboBuffer[i]).enforceVK("vkCreateBuffer");

            VkMemoryRequirements memReqs;
            vkGetBufferMemoryRequirements(device, ssboBuffer[i], &memReqs);

            VkMemoryAllocateInfo aInfo = {
                sType:           VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                allocationSize:  memReqs.size,
                memoryTypeIndex: findMemoryType(memReqs.memoryTypeBits,
                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
            };
            vkAllocateMemory(device, &aInfo, null, &ssboMemory[i]).enforceVK("vkAllocateMemory");
            vkBindBufferMemory(device, ssboBuffer[i], ssboMemory[i], 0).enforceVK;
            vkMapMemory(device, ssboMemory[i], 0, bufSize, 0, &ssboBufMapped[i]).enforceVK;
        }
    }

    private void createDescriptors()
    {
        VkDescriptorPoolSize poolSize = {
            type:            VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            descriptorCount: MAX_FRAMES,
        };
        VkDescriptorPoolCreateInfo poolInfo = {
            sType:         VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            maxSets:       MAX_FRAMES,
            poolSizeCount: 1,
            pPoolSizes:    &poolSize,
        };
        vkCreateDescriptorPool(device, &poolInfo, null, &descPool)
            .enforceVK("vkCreateDescriptorPool");

        VkDescriptorSetLayout[MAX_FRAMES] layouts;
        layouts[] = descSetLayout;

        VkDescriptorSetAllocateInfo allocInfo = {
            sType:              VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool:     descPool,
            descriptorSetCount: MAX_FRAMES,
            pSetLayouts:        layouts.ptr,
        };
        vkAllocateDescriptorSets(device, &allocInfo, descSets.ptr)
            .enforceVK("vkAllocateDescriptorSets");

        VkDeviceSize bufSize = RectInstance.sizeof * MAX_RECTS;
        foreach (i; 0 .. MAX_FRAMES)
        {
            VkDescriptorBufferInfo bufInfo = {
                buffer: ssboBuffer[i],
                offset: 0,
                range:  bufSize,
            };
            VkWriteDescriptorSet write = {
                sType:           VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet:          descSets[i],
                dstBinding:      0,
                descriptorType:  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                pBufferInfo:     &bufInfo,
            };
            vkUpdateDescriptorSets(device, 1, &write, 0, null);
        }
    }

    private void createRectPipeline()
    {
        auto vertCode = cast(immutable(ubyte)[]) import("rect.vert.spv");
        auto fragCode = cast(immutable(ubyte)[]) import("rect.frag.spv");

        auto vertMod = createShaderModule(vertCode);
        auto fragMod = createShaderModule(fragCode);
        scope(exit)
        {
            vkDestroyShaderModule(device, vertMod, null);
            vkDestroyShaderModule(device, fragMod, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages = [
            {
                sType:   VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                stage:   VK_SHADER_STAGE_VERTEX_BIT,
                module_: vertMod,
                pName:   "main".ptr,
            },
            {
                sType:   VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                stage:   VK_SHADER_STAGE_FRAGMENT_BIT,
                module_: fragMod,
                pName:   "main".ptr,
            },
        ];

        // 頂点バッファなし (シェーダ内でクワッド生成)
        VkPipelineVertexInputStateCreateInfo vertInput = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        };

        VkPipelineInputAssemblyStateCreateInfo inputAssembly = {
            sType:    VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        };

        // ビューポートとシザーは動的に設定 (リサイズ時にパイプライン再生成不要)
        VkDynamicState[2] dynStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynState = {
            sType:             VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount: 2,
            pDynamicStates:    dynStates.ptr,
        };

        VkPipelineViewportStateCreateInfo viewportState = {
            sType:         VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount: 1,
            scissorCount:  1,
        };

        VkPipelineRasterizationStateCreateInfo rasterizer = {
            sType:       VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            polygonMode: VK_POLYGON_MODE_FILL,
            cullMode:    VK_CULL_MODE_NONE,
            frontFace:   VK_FRONT_FACE_COUNTER_CLOCKWISE,
            lineWidth:   1.0f,
        };

        VkPipelineMultisampleStateCreateInfo multisampling = {
            sType:                VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
        };

        // アルファブレンディング有効
        VkPipelineColorBlendAttachmentState blendAttach = {
            colorWriteMask:      VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                 VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
            blendEnable:         VK_TRUE,
            srcColorBlendFactor: VK_BLEND_FACTOR_SRC_ALPHA,
            dstColorBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            colorBlendOp:        VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
            alphaBlendOp:        VK_BLEND_OP_ADD,
        };

        VkPipelineColorBlendStateCreateInfo blending = {
            sType:           VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount: 1,
            pAttachments:    &blendAttach,
        };

        VkPipelineLayoutCreateInfo layoutInfo = {
            sType:          VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            setLayoutCount: 1,
            pSetLayouts:    &descSetLayout,
        };
        vkCreatePipelineLayout(device, &layoutInfo, null, &pipelineLayout)
            .enforceVK("vkCreatePipelineLayout");

        VkGraphicsPipelineCreateInfo pipelineInfo = {
            sType:               VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount:          2,
            pStages:             stages.ptr,
            pVertexInputState:   &vertInput,
            pInputAssemblyState: &inputAssembly,
            pViewportState:      &viewportState,
            pRasterizationState: &rasterizer,
            pMultisampleState:   &multisampling,
            pColorBlendState:    &blending,
            pDynamicState:       &dynState,
            layout:              pipelineLayout,
            renderPass:          renderPass,
            subpass:             0,
        };
        vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, null, &rectPipeline)
            .enforceVK("vkCreateGraphicsPipelines");
    }

    // -------------------------------------------------------------------
    // Glyph bitmap atlas pipeline
    // -------------------------------------------------------------------

    private void createGlyphDescSetLayout()
    {
        VkDescriptorSetLayoutBinding[2] bindings = [
            {
                binding:         0,
                descriptorType:  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                stageFlags:      VK_SHADER_STAGE_VERTEX_BIT,
            },
            {
                binding:         1,
                descriptorType:  VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                stageFlags:      VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        ];
        VkDescriptorSetLayoutCreateInfo info = {
            sType:        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            bindingCount: 2,
            pBindings:    bindings.ptr,
        };
        vkCreateDescriptorSetLayout(device, &info, null, &glyphDescSetLayout)
            .enforceVK("vkCreateDescriptorSetLayout (glyph)");
    }

    private void createGlyphSsboBuffers()
    {
        VkDeviceSize bufSize = GlyphInstance.sizeof * MAX_GLYPHS;
        foreach (i; 0 .. MAX_FRAMES)
        {
            VkBufferCreateInfo bInfo = {
                sType:       VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                size:        bufSize,
                usage:       VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            };
            vkCreateBuffer(device, &bInfo, null, &glyphSsboBuffer[i]).enforceVK;

            VkMemoryRequirements memReqs;
            vkGetBufferMemoryRequirements(device, glyphSsboBuffer[i], &memReqs);

            VkMemoryAllocateInfo aInfo = {
                sType:           VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                allocationSize:  memReqs.size,
                memoryTypeIndex: findMemoryType(memReqs.memoryTypeBits,
                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
            };
            vkAllocateMemory(device, &aInfo, null, &glyphSsboMemory[i]).enforceVK;
            vkBindBufferMemory(device, glyphSsboBuffer[i], glyphSsboMemory[i], 0).enforceVK;
            vkMapMemory(device, glyphSsboMemory[i], 0, bufSize, 0,
                        &glyphSsboBufMapped[i]).enforceVK;
        }
    }

    private void createGlyphDescriptors()
    {
        VkDescriptorPoolSize[2] poolSizes = [
            { type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,         descriptorCount: MAX_FRAMES },
            { type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: MAX_FRAMES },
        ];
        VkDescriptorPoolCreateInfo poolInfo = {
            sType:         VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            maxSets:       MAX_FRAMES,
            poolSizeCount: 2,
            pPoolSizes:    poolSizes.ptr,
        };
        vkCreateDescriptorPool(device, &poolInfo, null, &glyphDescPool)
            .enforceVK("vkCreateDescriptorPool (glyph)");

        VkDescriptorSetLayout[MAX_FRAMES] layouts;
        layouts[] = glyphDescSetLayout;
        VkDescriptorSetAllocateInfo allocInfo = {
            sType:              VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            descriptorPool:     glyphDescPool,
            descriptorSetCount: MAX_FRAMES,
            pSetLayouts:        layouts.ptr,
        };
        vkAllocateDescriptorSets(device, &allocInfo, glyphDescSets.ptr)
            .enforceVK("vkAllocateDescriptorSets (glyph)");

        VkDeviceSize bufSize = GlyphInstance.sizeof * MAX_GLYPHS;
        foreach (i; 0 .. MAX_FRAMES)
        {
            VkDescriptorBufferInfo bufInfo = {
                buffer: glyphSsboBuffer[i],
                offset: 0,
                range:  bufSize,
            };
            VkWriteDescriptorSet write = {
                sType:           VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet:          glyphDescSets[i],
                dstBinding:      0,
                descriptorType:  VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                descriptorCount: 1,
                pBufferInfo:     &bufInfo,
            };
            vkUpdateDescriptorSets(device, 1, &write, 0, null);
        }
    }

    private void createGlyphPipeline()
    {
        auto vertCode = cast(immutable(ubyte)[]) import("glyph.vert.spv");
        auto fragCode = cast(immutable(ubyte)[]) import("glyph.frag.spv");

        auto vertMod = createShaderModule(vertCode);
        auto fragMod = createShaderModule(fragCode);
        scope(exit)
        {
            vkDestroyShaderModule(device, vertMod, null);
            vkDestroyShaderModule(device, fragMod, null);
        }

        VkPipelineShaderStageCreateInfo[2] stages = [
            {
                sType:   VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                stage:   VK_SHADER_STAGE_VERTEX_BIT,
                module_: vertMod,
                pName:   "main".ptr,
            },
            {
                sType:   VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                stage:   VK_SHADER_STAGE_FRAGMENT_BIT,
                module_: fragMod,
                pName:   "main".ptr,
            },
        ];

        VkPipelineVertexInputStateCreateInfo vertInput = {
            sType: VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        };
        VkPipelineInputAssemblyStateCreateInfo inputAssembly = {
            sType:    VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology: VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        };

        VkDynamicState[2] dynStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR];
        VkPipelineDynamicStateCreateInfo dynState = {
            sType:             VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount: 2,
            pDynamicStates:    dynStates.ptr,
        };
        VkPipelineViewportStateCreateInfo viewportState = {
            sType:         VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            viewportCount: 1,
            scissorCount:  1,
        };
        VkPipelineRasterizationStateCreateInfo rasterizer = {
            sType:       VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            polygonMode: VK_POLYGON_MODE_FILL,
            cullMode:    VK_CULL_MODE_NONE,
            frontFace:   VK_FRONT_FACE_COUNTER_CLOCKWISE,
            lineWidth:   1.0f,
        };
        VkPipelineMultisampleStateCreateInfo multisampling = {
            sType:                VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples: VK_SAMPLE_COUNT_1_BIT,
        };

        VkPipelineColorBlendAttachmentState blendAttach = {
            colorWriteMask:      VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                 VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
            blendEnable:         VK_TRUE,
            srcColorBlendFactor: VK_BLEND_FACTOR_SRC_ALPHA,
            dstColorBlendFactor: VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            colorBlendOp:        VK_BLEND_OP_ADD,
            srcAlphaBlendFactor: VK_BLEND_FACTOR_ONE,
            dstAlphaBlendFactor: VK_BLEND_FACTOR_ZERO,
            alphaBlendOp:        VK_BLEND_OP_ADD,
        };
        VkPipelineColorBlendStateCreateInfo blending = {
            sType:           VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount: 1,
            pAttachments:    &blendAttach,
        };

        VkPipelineLayoutCreateInfo layoutInfo = {
            sType:          VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            setLayoutCount: 1,
            pSetLayouts:    &glyphDescSetLayout,
        };
        vkCreatePipelineLayout(device, &layoutInfo, null, &glyphPipelineLayout)
            .enforceVK("vkCreatePipelineLayout (glyph)");

        VkGraphicsPipelineCreateInfo pipelineInfo = {
            sType:               VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            stageCount:          2,
            pStages:             stages.ptr,
            pVertexInputState:   &vertInput,
            pInputAssemblyState: &inputAssembly,
            pViewportState:      &viewportState,
            pRasterizationState: &rasterizer,
            pMultisampleState:   &multisampling,
            pColorBlendState:    &blending,
            pDynamicState:       &dynState,
            layout:              glyphPipelineLayout,
            renderPass:          renderPass,
            subpass:             0,
        };
        vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, null, &glyphPipeline)
            .enforceVK("vkCreateGraphicsPipelines (glyph)");
    }

    /// グリフアトラス (R8) を GPU にアップロードし、descriptor set を更新する。
    /// アトラスが変化するたびに呼び出す。
    void uploadAtlas(ref GlyphAtlas atlas)
    {
        import core.stdc.string : memcpy;

        uint w = GlyphAtlas.SIZE;
        uint h = GlyphAtlas.SIZE;
        VkDeviceSize imgSize = w * h; // R8: 1 byte per pixel

        // 1. Staging buffer 作成
        VkBuffer       stagingBuf;
        VkDeviceMemory stagingMem;
        {
            VkBufferCreateInfo bInfo = {
                sType:       VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                size:        imgSize,
                usage:       VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                sharingMode: VK_SHARING_MODE_EXCLUSIVE,
            };
            vkCreateBuffer(device, &bInfo, null, &stagingBuf).enforceVK;

            VkMemoryRequirements memReqs;
            vkGetBufferMemoryRequirements(device, stagingBuf, &memReqs);
            VkMemoryAllocateInfo aInfo = {
                sType:           VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                allocationSize:  memReqs.size,
                memoryTypeIndex: findMemoryType(memReqs.memoryTypeBits,
                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
            };
            vkAllocateMemory(device, &aInfo, null, &stagingMem).enforceVK;
            vkBindBufferMemory(device, stagingBuf, stagingMem, 0).enforceVK;

            void* mapped;
            vkMapMemory(device, stagingMem, 0, imgSize, 0, &mapped).enforceVK;
            memcpy(mapped, atlas.pixels.ptr, imgSize);
            vkUnmapMemory(device, stagingMem);
        }
        scope(exit)
        {
            vkDestroyBuffer(device, stagingBuf, null);
            vkFreeMemory   (device, stagingMem, null);
        }

        // 2. アトラスイメージ作成 (初回のみ)
        if (atlasImage == VK_NULL_HANDLE)
        {
            VkImageCreateInfo imgInfo = {
                sType:         VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                imageType:     VK_IMAGE_TYPE_2D,
                format:        VK_FORMAT_R8_UNORM,
                extent:        VkExtent3D(w, h, 1),
                mipLevels:     1,
                arrayLayers:   1,
                samples:       VK_SAMPLE_COUNT_1_BIT,
                tiling:        VK_IMAGE_TILING_OPTIMAL,
                usage:         VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                sharingMode:   VK_SHARING_MODE_EXCLUSIVE,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            };
            vkCreateImage(device, &imgInfo, null, &atlasImage).enforceVK("vkCreateImage (atlas)");

            VkMemoryRequirements memReqs;
            vkGetImageMemoryRequirements(device, atlasImage, &memReqs);
            VkMemoryAllocateInfo aInfo = {
                sType:           VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                allocationSize:  memReqs.size,
                memoryTypeIndex: findMemoryType(memReqs.memoryTypeBits,
                    VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
            };
            vkAllocateMemory(device, &aInfo, null, &atlasMemory).enforceVK;
            vkBindImageMemory(device, atlasImage, atlasMemory, 0).enforceVK;

            VkImageViewCreateInfo viewInfo = {
                sType:    VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                image:    atlasImage,
                viewType: VK_IMAGE_VIEW_TYPE_2D,
                format:   VK_FORMAT_R8_UNORM,
                subresourceRange: VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1),
            };
            vkCreateImageView(device, &viewInfo, null, &atlasImageView)
                .enforceVK("vkCreateImageView (atlas)");

            VkSamplerCreateInfo samplerInfo = {
                sType:        VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                magFilter:    VK_FILTER_LINEAR,
                minFilter:    VK_FILTER_LINEAR,
                mipmapMode:   VK_SAMPLER_MIPMAP_MODE_NEAREST,
                addressModeU: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeV: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                addressModeW: VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
                minLod:       0.0f,
                maxLod:       0.0f,
            };
            vkCreateSampler(device, &samplerInfo, null, &atlasSampler)
                .enforceVK("vkCreateSampler (atlas)");
        }

        // 3. 一時コマンドバッファで転送
        VkCommandBufferAllocateInfo cbAllocInfo = {
            sType:              VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool:        cmdPool,
            level:              VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            commandBufferCount: 1,
        };
        VkCommandBuffer cmd;
        vkAllocateCommandBuffers(device, &cbAllocInfo, &cmd).enforceVK;
        scope(exit) vkFreeCommandBuffers(device, cmdPool, 1, &cmd);

        VkCommandBufferBeginInfo beginInfo = {
            sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            flags: VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        vkBeginCommandBuffer(cmd, &beginInfo).enforceVK;

        // UNDEFINED → TRANSFER_DST_OPTIMAL
        VkImageMemoryBarrier barrier1 = {
            sType:               VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            srcAccessMask:       0,
            dstAccessMask:       VK_ACCESS_TRANSFER_WRITE_BIT,
            oldLayout:           VK_IMAGE_LAYOUT_UNDEFINED,
            newLayout:           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image:               atlasImage,
            subresourceRange:    VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1),
        };
        vkCmdPipelineBarrier(cmd,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, 0, null, 0, null, 1, &barrier1);

        VkBufferImageCopy region = {
            imageSubresource: VkImageSubresourceLayers(VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1),
            imageExtent:      VkExtent3D(w, h, 1),
        };
        vkCmdCopyBufferToImage(cmd, stagingBuf, atlasImage,
            VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        // TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL
        VkImageMemoryBarrier barrier2 = {
            sType:               VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            srcAccessMask:       VK_ACCESS_TRANSFER_WRITE_BIT,
            dstAccessMask:       VK_ACCESS_SHADER_READ_BIT,
            oldLayout:           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            newLayout:           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            srcQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex: VK_QUEUE_FAMILY_IGNORED,
            image:               atlasImage,
            subresourceRange:    VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1),
        };
        vkCmdPipelineBarrier(cmd,
            VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0, 0, null, 0, null, 1, &barrier2);

        vkEndCommandBuffer(cmd).enforceVK;

        VkSubmitInfo submitInfo = {
            sType:              VK_STRUCTURE_TYPE_SUBMIT_INFO,
            commandBufferCount: 1,
            pCommandBuffers:    &cmd,
        };
        vkQueueSubmit(graphicsQueue, 1, &submitInfo, VK_NULL_HANDLE).enforceVK;
        vkQueueWaitIdle(graphicsQueue).enforceVK;

        // 4. descriptor set の binding 1 を更新 (image sampler)
        VkDescriptorImageInfo imgDescInfo = {
            sampler:     atlasSampler,
            imageView:   atlasImageView,
            imageLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        foreach (i; 0 .. MAX_FRAMES)
        {
            VkWriteDescriptorSet write = {
                sType:           VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                dstSet:          glyphDescSets[i],
                dstBinding:      1,
                descriptorType:  VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                descriptorCount: 1,
                pImageInfo:      &imgDescInfo,
            };
            vkUpdateDescriptorSets(device, 1, &write, 0, null);
        }

        atlas.dirty = false;
    }

    // -------------------------------------------------------------------

    void renderFrame()
    {
        vkWaitForFences(device, 1, &inFlight[currentFrame], VK_TRUE, ulong.max);

        uint imageIndex;
        VkResult res = vkAcquireNextImageKHR(
            device, swapchain, ulong.max,
            imageAvailable[currentFrame], VK_NULL_HANDLE, &imageIndex
        );
        if (res == VK_ERROR_OUT_OF_DATE_KHR) { recreateSwapchain(); return; }

        vkResetFences(device, 1, &inFlight[currentFrame]);

        // SSBO に矩形データをアップロード
        size_t rectCount = rects.length > MAX_RECTS ? MAX_RECTS : rects.length;
        if (rectCount > 0)
        {
            import core.stdc.string : memcpy;
            memcpy(ssboBufMapped[currentFrame], rects.ptr,
                   RectInstance.sizeof * rectCount);
        }

        auto cmd = cmdBuffers[imageIndex];
        VkCommandBufferBeginInfo beginInfo = {
            sType: VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };
        vkBeginCommandBuffer(cmd, &beginInfo).enforceVK;

        VkClearValue clearColor;
        clearColor.color.float32 = [0.1f, 0.1f, 0.1f, 1.0f];

        VkRenderPassBeginInfo rpInfo = {
            sType:           VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            renderPass:      renderPass,
            framebuffer:     framebuffers[imageIndex],
            renderArea:      VkRect2D(VkOffset2D(0, 0), swapExtent),
            clearValueCount: 1,
            pClearValues:    &clearColor,
        };
        vkCmdBeginRenderPass(cmd, &rpInfo, VK_SUBPASS_CONTENTS_INLINE);

        VkViewport vp = {
            x: 0.0f, y: 0.0f,
            width:    cast(float) swapExtent.width,
            height:   cast(float) swapExtent.height,
            minDepth: 0.0f,
            maxDepth: 1.0f,
        };
        VkRect2D sc = { offset: VkOffset2D(0, 0), extent: swapExtent };
        vkCmdSetViewport(cmd, 0, 1, &vp);
        vkCmdSetScissor (cmd, 0, 1, &sc);

        if (rectCount > 0)
        {
            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, rectPipeline);
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                pipelineLayout, 0, 1, &descSets[currentFrame], 0, null);
            vkCmdDraw(cmd, 6, cast(uint) rectCount, 0, 0);
        }

        // Glyph draw
        size_t glyphCount = glyphs.length > MAX_GLYPHS ? MAX_GLYPHS : glyphs.length;
        if (glyphCount > 0 && atlasImage != VK_NULL_HANDLE)
        {
            import core.stdc.string : memcpy;
            memcpy(glyphSsboBufMapped[currentFrame], glyphs.ptr,
                   GlyphInstance.sizeof * glyphCount);

            vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, glyphPipeline);
            vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS,
                glyphPipelineLayout, 0, 1, &glyphDescSets[currentFrame], 0, null);
            vkCmdDraw(cmd, 6, cast(uint) glyphCount, 0, 0);
        }

        vkCmdEndRenderPass(cmd);
        vkEndCommandBuffer(cmd).enforceVK;

        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        VkSubmitInfo submitInfo = {
            sType:                VK_STRUCTURE_TYPE_SUBMIT_INFO,
            waitSemaphoreCount:   1,
            pWaitSemaphores:      &imageAvailable[currentFrame],
            pWaitDstStageMask:    &waitStage,
            commandBufferCount:   1,
            pCommandBuffers:      &cmd,
            signalSemaphoreCount: 1,
            pSignalSemaphores:    &renderFinished[currentFrame],
        };
        vkQueueSubmit(graphicsQueue, 1, &submitInfo, inFlight[currentFrame]).enforceVK;

        VkPresentInfoKHR presentInfo = {
            sType:              VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            waitSemaphoreCount: 1,
            pWaitSemaphores:    &renderFinished[currentFrame],
            swapchainCount:     1,
            pSwapchains:        &swapchain,
            pImageIndices:      &imageIndex,
        };
        res = vkQueuePresentKHR(presentQueue, &presentInfo);
        if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR || needsResize)
        {
            needsResize = false;
            recreateSwapchain();
        }

        currentFrame = (currentFrame + 1) % MAX_FRAMES;
    }

    void resize(uint w, uint h)
    {
        width = w; height = h;
        needsResize = true;
    }

    // -------------------------------------------------------------------

    private void recreateSwapchain()
    {
        vkDeviceWaitIdle(device);
        cleanupSwapchain();
        createSwapchain();
        createFramebuffers();
        allocCommandBuffers();
    }

    private void cleanupSwapchain()
    {
        foreach (fb; framebuffers)   vkDestroyFramebuffer(device, fb, null);
        foreach (iv; swapImageViews) vkDestroyImageView  (device, iv, null);
        vkDestroySwapchainKHR(device, swapchain, null);
        framebuffers   = null;
        swapImageViews = null;
        swapImages     = null;
    }

    void cleanup()
    {
        vkDeviceWaitIdle(device);
        foreach (i; 0 .. MAX_FRAMES)
        {
            vkDestroySemaphore(device, renderFinished[i], null);
            vkDestroySemaphore(device, imageAvailable[i], null);
            vkDestroyFence    (device, inFlight[i],       null);
        }
        vkDestroyCommandPool(device, cmdPool, null);
        cleanupSwapchain();
        vkDestroyRenderPass(device, renderPass, null);

        vkDestroyPipeline      (device, rectPipeline,  null);
        vkDestroyPipelineLayout(device, pipelineLayout, null);
        vkDestroyDescriptorPool(device, descPool,       null);
        vkDestroyDescriptorSetLayout(device, descSetLayout, null);
        foreach (i; 0 .. MAX_FRAMES)
        {
            vkUnmapMemory   (device, ssboMemory[i]);
            vkDestroyBuffer (device, ssboBuffer[i], null);
            vkFreeMemory    (device, ssboMemory[i], null);
        }

        if (atlasImage != VK_NULL_HANDLE)
        {
            vkDestroySampler  (device, atlasSampler,   null);
            vkDestroyImageView(device, atlasImageView, null);
            vkDestroyImage    (device, atlasImage,     null);
            vkFreeMemory      (device, atlasMemory,    null);
        }
        vkDestroyPipeline      (device, glyphPipeline,       null);
        vkDestroyPipelineLayout(device, glyphPipelineLayout,  null);
        vkDestroyDescriptorPool(device, glyphDescPool,        null);
        vkDestroyDescriptorSetLayout(device, glyphDescSetLayout, null);
        foreach (i; 0 .. MAX_FRAMES)
        {
            vkUnmapMemory   (device, glyphSsboMemory[i]);
            vkDestroyBuffer (device, glyphSsboBuffer[i], null);
            vkFreeMemory    (device, glyphSsboMemory[i], null);
        }

        vkDestroyDevice    (device, null);
        vkDestroySurfaceKHR(instance, surface, null);
        vkDestroyInstance  (instance, null);
    }
}
