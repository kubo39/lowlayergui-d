module vulkan_setup;

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

private void enforceVK(VkResult r, string msg = "Vulkan error")
{
    if (r != VK_SUCCESS)
        throw new Exception(msg ~ ": " ~ r.to!string);
}

// ---------------------------------------------------------------------------

class VulkanSetup
{
    enum MAX_FRAMES = 2;

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

        // コマンドバッファを毎フレーム記録 (クリアカラーのみ)
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
        foreach (fb; framebuffers)    vkDestroyFramebuffer(device, fb, null);
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
        vkDestroyRenderPass (device, renderPass, null);
        vkDestroyDevice     (device, null);
        vkDestroySurfaceKHR (instance, surface, null);
        vkDestroyInstance   (instance, null);
    }
}
