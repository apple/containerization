//

#pragma once

#include "archive.h"
#include <stdint.h>

void archive_set_error_wrapper(struct archive *a, int error_number, const char *error_string);
