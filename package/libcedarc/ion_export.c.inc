
/* Added by carplay-linux: export the ION dma-buf fd for a buffer's CPU virtual
 * address, so an application can hand the decoded frame to DRM via PRIME
 * (zero-copy display). Upstream sets VideoPicture.nBufFd only on some paths;
 * the decode FBM path leaves it unset, so we look the fd up in the buffer list
 * (same lookup the OREO cache-flush uses). Returns the fd, or -1. */
int ion_alloc_get_dmabuf_fd(void *vir_addr)
{
	buffer_node *tmp;
	unsigned long vir = (unsigned long)vir_addr;

	if (!g_alloc_context)
		return -1;
	aw_mem_list_for_each_entry(tmp, &g_alloc_context->list, i_list) {
		if (vir >= tmp->vir && vir < tmp->vir + tmp->size)
			return tmp->fd_data.aw_fd;
	}
	return -1;
}
