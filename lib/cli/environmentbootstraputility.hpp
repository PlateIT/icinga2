// SPDX-FileCopyrightText: 2026 Icinga GmbH <https://icinga.com>
// SPDX-License-Identifier: GPL-2.0-or-later

#ifndef ENVIRONMENTBOOTSTRAPUTILITY_H
#define ENVIRONMENTBOOTSTRAPUTILITY_H

#include "base/i2-base.hpp"

namespace icinga
{

/** Declarative, idempotent node bootstrap for containerized daemon starts. */
class EnvironmentBootstrapUtility
{
public:
	static bool Run();

private:
	EnvironmentBootstrapUtility();
};

}

#endif /* ENVIRONMENTBOOTSTRAPUTILITY_H */
