import DummyBackend

@testable @_spi(Backends) import SwiftCrossUI

/// The proposals the recorded baseline was captured under, in order.
let baselineProposals: [ProposedViewSize] = [
    ProposedViewSize(200, 200),
    ProposedViewSize(80, 400),
    ProposedViewSize(400, nil),
    ProposedViewSize(nil, 150),
    ProposedViewSize(nil, nil),
]

/// Fingerprints of the geometry that `randomTree(depth: 3)` committed under
/// the implementation that preceded alignment guides, recorded from
/// `bc76387` — the commit this branch was cut from.
///
/// Regenerating these to make a failure go away defeats their purpose: a
/// diff here means guide-free layout moved, which the reduction claim says
/// cannot happen.
let preGuidesGeometry: [Int: [String]] = [
    0: [
        "413155fff0bb154d",
        "413155fff0bb154d",
        "413155fff0bb154d",
        "413155fff0bb154d",
        "413155fff0bb154d"
    ],
    1: [
        "2a2b67ceb2ed9eff",
        "2a2b67ceb2ed9eff",
        "2a2b67ceb2ed9eff",
        "2a2b67ceb2ed9eff",
        "2a2b67ceb2ed9eff"
    ],
    2: [
        "92d3876bcf2a9aed",
        "92d3876bcf2a9aed",
        "92d3876bcf2a9aed",
        "92d3876bcf2a9aed",
        "92d3876bcf2a9aed"
    ],
    3: [
        "98d4ff5b52363b20",
        "98d4ff5b52363b20",
        "98d4ff5b52363b20",
        "98d4ff5b52363b20",
        "98d4ff5b52363b20"
    ],
    4: [
        "6e9a2a43a6e58c4",
        "898dfdd869b76afc",
        "6e9a2a43a6e58c4",
        "6e9a2a43a6e58c4",
        "6e9a2a43a6e58c4"
    ],
    5: [
        "7e57ed03c85b5936",
        "7e57ed03c85b5936",
        "7e57ed03c85b5936",
        "7e57ed03c85b5936",
        "7e57ed03c85b5936"
    ],
    6: [
        "e8d9801651000b4d",
        "e8d9801651000b4d",
        "e8d9801651000b4d",
        "e8d9801651000b4d",
        "e8d9801651000b4d"
    ],
    7: [
        "65eeb41fa113e0a0",
        "65eeb41fa113e0a0",
        "65eeb41fa113e0a0",
        "65eeb41fa113e0a0",
        "65eeb41fa113e0a0"
    ],
    8: [
        "e66a7484707b33da",
        "e66a7484707b33da",
        "e66a7484707b33da",
        "e66a7484707b33da",
        "e66a7484707b33da"
    ],
    9: [
        "3de4c03ca8c1d9c2",
        "17d8bad9fc1c7dde",
        "3de4c03ca8c1d9c2",
        "3de4c03ca8c1d9c2",
        "3de4c03ca8c1d9c2"
    ],
    10: [
        "15ffee8b510c15fb",
        "86d5acc2161a02c",
        "15ffee8b510c15fb",
        "15ffee8b510c15fb",
        "15ffee8b510c15fb"
    ],
    11: [
        "605708804a72423",
        "f9b4d748d3348f2b",
        "605708804a72423",
        "605708804a72423",
        "605708804a72423"
    ],
    12: [
        "c19475ff6d7271a0",
        "4f593d22d6ba865f",
        "c19475ff6d7271a0",
        "c19475ff6d7271a0",
        "c19475ff6d7271a0"
    ],
    13: [
        "8ba839e103d06e6a",
        "8ba839e103d06e6a",
        "8ba839e103d06e6a",
        "8ba839e103d06e6a",
        "8ba839e103d06e6a"
    ],
    14: [
        "a7f9a0a0628d91ed",
        "a7f9a0a0628d91ed",
        "a7f9a0a0628d91ed",
        "a7f9a0a0628d91ed",
        "a7f9a0a0628d91ed"
    ],
    15: [
        "7c0a022b0d78a2ac",
        "a4b63f97a3682726",
        "11debdcb01c28782",
        "11debdcb01c28782",
        "11debdcb01c28782"
    ],
    16: [
        "d5be8ca6f8ecd26f",
        "c1f73bbdd515d60",
        "d5be8ca6f8ecd26f",
        "d5be8ca6f8ecd26f",
        "d5be8ca6f8ecd26f"
    ],
    17: [
        "1e0b9e816da6ec8d",
        "1e0b9e816da6ec8d",
        "1e0b9e816da6ec8d",
        "1e0b9e816da6ec8d",
        "1e0b9e816da6ec8d"
    ],
    18: [
        "f258cfa15695683d",
        "f258cfa15695683d",
        "f258cfa15695683d",
        "f258cfa15695683d",
        "f258cfa15695683d"
    ],
    19: [
        "5f2cb93a7b26f355",
        "e96d5a23b06a007f",
        "4889fbceec8a9fc8",
        "4889fbceec8a9fc8",
        "4889fbceec8a9fc8"
    ],
    20: [
        "d691cf37c85861ea",
        "74d354550b9e1966",
        "d691cf37c85861ea",
        "d691cf37c85861ea",
        "d691cf37c85861ea"
    ],
    21: [
        "857d266a408c7c7e",
        "857d266a408c7c7e",
        "857d266a408c7c7e",
        "857d266a408c7c7e",
        "857d266a408c7c7e"
    ],
    22: [
        "7b9fedcf546b3d99",
        "df8c2e7b0485a30d",
        "7b9fedcf546b3d99",
        "7b9fedcf546b3d99",
        "7b9fedcf546b3d99"
    ],
    23: [
        "7dcfbde038b4cd53",
        "58744adf75efc9e0",
        "7dcfbde038b4cd53",
        "7dcfbde038b4cd53",
        "7dcfbde038b4cd53"
    ],
]
