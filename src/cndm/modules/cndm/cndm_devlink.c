// SPDX-License-Identifier: GPL
/*

Copyright (c) 2025 FPGA Ninja, LLC

Authors:
- Alex Forencich

*/

#include "cndm.h"

#include <linux/version.h>

static int cndm_devlink_info_get(struct devlink *devlink,
	struct devlink_info_req *req, struct netlink_ext_ack *extack)
{
	struct cndm_dev *cdev = devlink_priv(devlink);
	char str[32];
	int ret = 0;

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 2, 0)
	ret = devlink_info_driver_name_put(req, KBUILD_MODNAME);
	if (ret)
		return ret;
#endif

	snprintf(str, sizeof(str), "%08x", 0); // TODO

	ret = devlink_info_version_fixed_put(req, "fpga.id", str);
	if (ret)
		return ret;

	snprintf(str, sizeof(str), "%08x", 0); // TODO

	ret = devlink_info_version_fixed_put(req, DEVLINK_INFO_VERSION_GENERIC_BOARD_ID, str);
	if (ret)
		return ret;

	snprintf(str, sizeof(str), "%08x", 0); // TODO

	ret = devlink_info_version_fixed_put(req, DEVLINK_INFO_VERSION_GENERIC_BOARD_REV, str);
	if (ret)
		return ret;

	snprintf(str, sizeof(str), "%08x", 0); // TODO

	ret = devlink_info_version_running_put(req, "fw.id", str);
	if (ret)
		return ret;

	snprintf(str, sizeof(str), "%08x", 0); // TODO

	ret = devlink_info_version_running_put(req, DEVLINK_INFO_VERSION_GENERIC_FW, str);
	if (ret)
		return ret;

	return ret;
}

static const struct devlink_ops cndm_devlink_ops = {
	.info_get = cndm_devlink_info_get,
};

struct devlink *cndm_devlink_alloc(struct device *dev)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 15, 0)
	return devlink_alloc(&cndm_devlink_ops, sizeof(struct cndm_dev), dev);
#else
	return devlink_alloc(&cndm_devlink_ops, sizeof(struct cndm_dev));
#endif
}

void cndm_devlink_free(struct devlink *devlink) {
	devlink_free(devlink);
}
